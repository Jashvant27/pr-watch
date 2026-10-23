import Foundation

/// The two GitHub REST calls the widget and the app make, with the error states the widget shows.
struct GitHubClient {
    let token: String

    static let apiBase = URL(string: "https://api.github.com")!
    /// How many PRs get the single-PR call for their comment counts per refresh. The list
    /// endpoint carries no comment counts, so each counted PR costs one extra request.
    static let detailLimit = 30
    static let pageSize = 100
    /// No URL cache: GitHub answers with `Cache-Control: max-age=60`, and the shared session would
    /// serve a refresh pressed within a minute of the last fetch from that cache, list unchanged.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    enum Failure: Error, LocalizedError {
        case unauthorized
        case forbidden
        case notFound
        case rateLimited(until: Date?)
        case http(Int)
        case network(String)
        case decoding(String)

        /// The short text the widget shows.
        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Not authorised: open PR Watch to sign in"
            case .forbidden: return "Access denied (403): the token cannot read this repository"
            case .notFound: return "Repository not found (or the token cannot see it)"
            case .rateLimited(let until):
                if let until { return "Rate limited until \(until.formatted(date: .omitted, time: .shortened))" }
                return "Rate limited by GitHub"
            case .http(let code): return "GitHub answered \(code)"
            case .network(let text): return "No connection: \(text)"
            case .decoding(let text): return "Unexpected answer: \(text)"
            }
        }

        var status: Int? {
            switch self {
            case .unauthorized: return 401
            case .forbidden: return 403
            case .notFound: return 404
            case .rateLimited: return 429
            case .http(let code): return code
            case .network, .decoding: return nil
            }
        }
    }

    struct Response {
        let status: Int
        let data: Data
        let rateLimitRemaining: Int?
        let rateLimitReset: Date?
    }

    struct Meta {
        var rateLimitRemaining: Int?
        var rateLimitReset: Date?
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRWatch-macOS-widget", forHTTPHeaderField: "User-Agent")
        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await Self.session.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard let http = urlResponse as? HTTPURLResponse else { throw Failure.network("not an HTTP response") }
        let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        let response = Response(status: http.statusCode, data: data, rateLimitRemaining: remaining, rateLimitReset: reset)
        switch http.statusCode {
        case 200..<300: return response
        case 401: throw Failure.unauthorized
        case 403, 429:
            if remaining == 0 || http.statusCode == 429 || http.value(forHTTPHeaderField: "retry-after") != nil {
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init).map { Date(timeIntervalSinceNow: $0) }
                throw Failure.rateLimited(until: remaining == 0 ? reset : retryAfter ?? reset)
            }
            throw Failure.forbidden
        case 404: throw Failure.notFound
        default: throw Failure.http(http.statusCode)
        }
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private struct UserDTO: Decodable { let login: String }
    private struct LabelDTO: Decodable { let name: String; let color: String }
    private struct PullDTO: Decodable {
        struct Author: Decodable { let login: String }
        let number: Int
        let title: String
        let htmlUrl: URL
        let draft: Bool?
        let createdAt: Date
        let user: Author?
        let labels: [LabelDTO]?
        let comments: Int?
        let reviewComments: Int?
    }

    /// `GET /user`: the login the token belongs to.
    func login() async throws -> String {
        let response = try await get("user")
        do { return try Self.decoder.decode(UserDTO.self, from: response.data).login } catch { throw Failure.decoding(error.localizedDescription) }
    }

    /// The repository's open pull requests, newest first, with comment counts for the first
    /// `detailLimit` of them.
    func openPulls(of repo: RepoRef) async throws -> (RepoSnapshot, Meta) {
        let list = try await get("repos/\(repo.owner)/\(repo.name)/pulls", query: [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc"),
        ])
        let dtos: [PullDTO]
        do { dtos = try Self.decoder.decode([PullDTO].self, from: list.data) } catch { throw Failure.decoding(error.localizedDescription) }
        var meta = Meta(rateLimitRemaining: list.rateLimitRemaining, rateLimitReset: list.rateLimitReset)

        // Comment counts: the single-PR endpoint, a few at a time; a failed one just has no count.
        var counts: [Int: Int] = [:]
        await withTaskGroup(of: (Int, Int?, Meta?).self) { group in
            for dto in dtos.prefix(Self.detailLimit) {
                group.addTask {
                    guard let response = try? await get("repos/\(repo.owner)/\(repo.name)/pulls/\(dto.number)"),
                          let detail = try? Self.decoder.decode(PullDTO.self, from: response.data) else { return (dto.number, nil, nil) }
                    let count = (detail.comments ?? 0) + (detail.reviewComments ?? 0)
                    return (dto.number, count, Meta(rateLimitRemaining: response.rateLimitRemaining, rateLimitReset: response.rateLimitReset))
                }
            }
            for await (number, count, m) in group {
                counts[number] = count
                if let m, let remaining = m.rateLimitRemaining, remaining < (meta.rateLimitRemaining ?? Int.max) { meta = m }
            }
        }

        let pulls = dtos.map { dto in
            PullRequest(number: dto.number, title: dto.title, htmlURL: dto.htmlUrl, author: dto.user?.login ?? "ghost",
                        createdAt: dto.createdAt, isDraft: dto.draft ?? false,
                        labels: (dto.labels ?? []).map { PRLabel(name: $0.name, color: $0.color) },
                        commentCount: counts[dto.number] ?? nil)
        }
        return (RepoSnapshot(fetchedAt: .now, pulls: pulls, truncated: dtos.count >= Self.pageSize), meta)
    }
}

/// Fetches one repository into its cache file, used by the widget's timeline and refresh button
/// and by the app. The cache is the handover between the two: the widget renders it instantly
/// and keeps the last list under an error.
enum RepoFetcher {
    static let notSignedIn = "Not signed in: open PR Watch to sign in"

    /// Fetches every repository that has a cache file, one after the other.
    static func refreshAll() async {
        for entry in SharedStore.allEntries() {
            _ = await refresh(entry.repo)
        }
    }

    /// Returns the cache entry after a fetch; `maxAge` skips the network when the snapshot is
    /// younger than that (the widget reloads right after its refresh button already fetched).
    static func refresh(_ repo: RepoRef, maxAge: TimeInterval = 0) async -> CacheEntry {
        var entry = SharedStore.loadEntry(for: repo) ?? CacheEntry(repo: repo)
        if maxAge > 0, let snapshot = entry.snapshot, Date.now.timeIntervalSince(snapshot.fetchedAt) < maxAge, entry.lastProblem == nil {
            return entry
        }
        entry.lastAttempt = .now
        let stored: TokenStore.Stored?
        do {
            stored = try TokenStore.load()
        } catch {
            entry.lastProblem = error.localizedDescription
            entry.lastStatus = nil
            SharedStore.saveEntry(entry)
            return entry
        }
        guard let stored else {
            entry.lastProblem = notSignedIn
            entry.lastStatus = nil
            SharedStore.saveEntry(entry)
            return entry
        }
        do {
            let (snapshot, meta) = try await GitHubClient(token: stored.token).openPulls(of: repo)
            entry.snapshot = snapshot
            entry.lastProblem = nil
            entry.lastStatus = 200
            entry.rateLimitRemaining = meta.rateLimitRemaining
            entry.rateLimitReset = meta.rateLimitReset
        } catch let failure as GitHubClient.Failure {
            entry.lastProblem = failure.errorDescription
            entry.lastStatus = failure.status
            if case .rateLimited(let until) = failure { entry.rateLimitRemaining = 0; entry.rateLimitReset = until }
        } catch {
            entry.lastProblem = error.localizedDescription
            entry.lastStatus = nil
        }
        SharedStore.saveEntry(entry)
        return entry
    }
}
