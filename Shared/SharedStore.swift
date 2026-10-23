import Foundation

/// The App Group container, shared by the app and the widget: one cache file per repository,
/// the account info and the debug-logging setting. Files, not UserDefaults: on macOS the
/// preferences daemon keeps App Group suite writes of a locally signed app in memory only.
enum SharedStore {
    static let appGroup = "R9KR5T3WZB.com.jashvantsewmangal.prwatch"

    /// `~/Library/Group Containers/<group>/Library/Application Support/PRWatch/`, or nil when
    /// this process has no access to the container.
    static var directory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent("Library/Application Support/PRWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cacheDirectory: URL? {
        guard let dir = directory?.appendingPathComponent("cache", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var settingsURL: URL? { directory?.appendingPathComponent("settings.json") }
    static var accountURL: URL? { directory?.appendingPathComponent("account.json") }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Cache

    static func cacheURL(for repo: RepoRef) -> URL? { cacheDirectory?.appendingPathComponent(repo.fileName) }

    static func loadEntry(for repo: RepoRef) -> CacheEntry? {
        guard let url = cacheURL(for: repo), let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CacheEntry.self, from: data)
    }

    /// The last error a write hit, for the diagnostics line.
    nonisolated(unsafe) static var lastWriteError: String?

    static func saveEntry(_ entry: CacheEntry) {
        guard let url = cacheURL(for: entry.repo) else { lastWriteError = "no group container"; return }
        do {
            try encoder.encode(entry).write(to: url, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
        }
    }

    static func removeEntry(for repo: RepoRef) {
        guard let url = cacheURL(for: repo) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every cached repository, most recently attempted first.
    static func allEntries() -> [CacheEntry] {
        guard let dir = cacheDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CacheEntry? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CacheEntry.self, from: data)
            }
            .sorted { ($0.lastAttempt ?? .distantPast) > ($1.lastAttempt ?? .distantPast) }
    }

    // MARK: Account

    static var account: AccountInfo? {
        get {
            guard let url = accountURL, let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AccountInfo.self, from: data)
        }
        set {
            guard let url = accountURL else { return }
            if let newValue, let data = try? encoder.encode(newValue) {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Settings

    /// `settings.json`: {"debugLogging": true} shows the diagnostics line in the app and the widget.
    static var debugLogging: Bool {
        get {
            guard let url = settingsURL, let data = try? Data(contentsOf: url),
                  let settings = try? JSONDecoder().decode([String: Bool].self, from: data) else { return false }
            return settings["debugLogging"] ?? false
        }
        set {
            guard let url = settingsURL, let data = try? JSONEncoder().encode(["debugLogging": newValue]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Where the cache lives, for the diagnostics line.
    static var location: String {
        guard let dir = cacheDirectory else { return "no group container" }
        return abbreviated(dir.path) + (lastWriteError.map { " · write failed: \($0)" } ?? "")
    }
}
