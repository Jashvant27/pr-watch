import Foundation

/// A GitHub repository, as `owner/name`.
struct RepoRef: Codable, Hashable {
    let owner: String
    let name: String

    var slug: String { "\(owner)/\(name)" }
    var htmlURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    var pullsURL: URL { htmlURL.appendingPathComponent("pulls") }
    /// The cache file's name: lowercase, `/` replaced, so one repository is one file whatever
    /// the user typed.
    var fileName: String { "\(owner.lowercased())__\(name.lowercased()).json" }

    /// Accepts what people paste: `owner/name`, `https://github.com/owner/name`,
    /// `github.com/owner/name/pulls`, `git@github.com:owner/name.git`. Trailing `.git`, slashes
    /// and anything after the repository name are dropped. Nil when it is not a repository.
    static func parse(_ text: String) -> RepoRef? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let range = s.range(of: "github.com", options: .caseInsensitive) {
            s = String(s[range.upperBound...])
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        if let q = name.firstIndex(where: { "?#".contains($0) }) { name = String(name[..<q]) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !owner.isEmpty, !name.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return RepoRef(owner: owner, name: name)
    }
}

struct PRLabel: Codable, Hashable {
    let name: String
    /// Six hex digits without `#`, as the API gives it.
    let color: String
}

struct PullRequest: Codable, Identifiable, Hashable {
    let number: Int
    let title: String
    let htmlURL: URL
    let author: String
    let createdAt: Date
    let isDraft: Bool
    let labels: [PRLabel]
    /// `comments + review_comments` from the single-PR endpoint; nil when that call failed.
    let commentCount: Int?

    var id: Int { number }
}

/// The last successful fetch of one repository.
struct RepoSnapshot: Codable {
    var fetchedAt: Date
    var pulls: [PullRequest]
    /// True when the list hit the API page size, so there are more open PRs than listed.
    var truncated: Bool
}

/// One cache file per repository in the App Group container: the last good list plus what the
/// last attempt returned, so the widget can show the old list under an error.
struct CacheEntry: Codable {
    var repo: RepoRef
    var snapshot: RepoSnapshot?
    var lastAttempt: Date?
    var lastStatus: Int?
    var lastProblem: String?
    var rateLimitRemaining: Int?
    var rateLimitReset: Date?

    init(repo: RepoRef) { self.repo = repo }
}

/// Who the token belongs to, written by the app after `GET /user`; not secret.
struct AccountInfo: Codable {
    var login: String
    var source: String
    var checkedAt: Date
}

enum RelativeTime {
    /// GitHub's wording for "opened …": "just now", "5 minutes ago", "18 hours ago", "yesterday",
    /// "3 days ago", "last week", "2 weeks ago", then "on 12 Sep" (with the year once it differs).
    static func github(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)
        let days = Int(seconds / 86400)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        case ..<86400: return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        case ..<(2 * 86400): return "yesterday"
        case ..<(7 * 86400): return "\(days) days ago"
        case ..<(14 * 86400): return "last week"
        case ..<(30 * 86400): return "\(days / 7) weeks ago"
        default:
            let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
            let style = Date.FormatStyle().day().month(.abbreviated)
            return "on " + (sameYear ? date.formatted(style) : date.formatted(style.year()))
        }
    }
}

enum LabelColor {
    /// `(r, g, b)` in 0…1 from the API's six hex digits; GitHub's grey when it is malformed.
    static func rgb(_ hex: String) -> (Double, Double, Double) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return (0.55, 0.55, 0.55) }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    /// True when black text reads better on this colour than white (W3C relative luminance).
    static func prefersDarkText(_ hex: String) -> Bool {
        let (r, g, b) = rgb(hex)
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return luminance > 0.4
    }
}
