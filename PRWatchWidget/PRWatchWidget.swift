import AppIntents
import SwiftUI
import WidgetKit

@main
struct PRWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        PullRequestsWidget()
    }
}

/// One repository's open pull requests, the way GitHub's list shows them. Each widget on the
/// desktop is configured with its own repository (Edit Widget → Repository).
/// The widget kind, outside the (main-actor) widget type so the refresh intent can name it.
let pullRequestsWidgetKind = "PRWatchWidget"

struct PullRequestsWidget: Widget {

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: pullRequestsWidgetKind, intent: RepositoryConfiguration.self, provider: PullsProvider()) { entry in
            PullsWidgetView(entry: entry)
        }
        .configurationDisplayName("Pull Requests")
        .description("The open pull requests of a GitHub repository, refreshed every hour.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Intents

/// The widget's configuration: which repository, and whether drafts count.
struct RepositoryConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pull Requests"
    static var description = IntentDescription("Shows the open pull requests of one GitHub repository.")

    @Parameter(title: "Repository", default: "")
    var repository: String

    @Parameter(title: "Include drafts", default: true)
    var includeDrafts: Bool
}

/// The ↻ button: fetches the repository now, then reloads the widget so the new list shows.
/// While it runs the footer is dimmed (`invalidatableContent`).
struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh pull requests"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Repository", default: "")
    var repository: String

    init() {}
    init(repository: String) { self.repository = repository }

    func perform() async throws -> some IntentResult {
        if let repo = RepoRef.parse(repository) {
            _ = await RepoFetcher.refresh(repo)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: pullRequestsWidgetKind)
        return .result()
    }
}

// MARK: - Timeline

struct PullsEntry: TimelineEntry {
    let date: Date
    /// Nil when the configuration text is empty or not a repository.
    let repo: RepoRef?
    let configuredText: String
    let pulls: [PullRequest]
    let truncated: Bool
    let fetchedAt: Date?
    let problem: String?
    let debug: String?

    static func from(_ entry: CacheEntry, includeDrafts: Bool, text: String, date: Date = .now) -> PullsEntry {
        let pulls = (entry.snapshot?.pulls ?? []).filter { includeDrafts || !$0.isDraft }
        var debug: String?
        if SharedStore.debugLogging {
            var parts = [SharedStore.location, TokenStore.diagnostics]
            parts.append("status \(entry.lastStatus.map(String.init) ?? "–")")
            if let remaining = entry.rateLimitRemaining {
                parts.append("rate \(remaining)" + (entry.rateLimitReset.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
            }
            debug = parts.joined(separator: " · ")
        }
        return PullsEntry(date: date, repo: entry.repo, configuredText: text, pulls: pulls,
                          truncated: entry.snapshot?.truncated ?? false, fetchedAt: entry.snapshot?.fetchedAt,
                          problem: entry.lastProblem, debug: debug)
    }

    /// What the widget gallery shows.
    static var sample: PullsEntry {
        let repo = RepoRef(owner: "octocat", name: "hello-world")
        let now = Date.now
        let pulls = [
            PullRequest(number: 371, title: "Open the settings screen directly from the dashboard", htmlURL: repo.pullsURL,
                        author: "octocat", createdAt: now.addingTimeInterval(-18 * 3600), isDraft: false,
                        labels: [PRLabel(name: "claude", color: "b64d02")], commentCount: 31),
            PullRequest(number: 368, title: "Onboarding: skip the pairing step when no device is found", htmlURL: repo.pullsURL,
                        author: "hubot", createdAt: now.addingTimeInterval(-3 * 86400), isDraft: false,
                        labels: [PRLabel(name: "bug", color: "d73a4a"), PRLabel(name: "good first issue", color: "7057ff")], commentCount: 4),
            PullRequest(number: 362, title: "Build: run the new networking stack by default", htmlURL: repo.pullsURL,
                        author: "octocat", createdAt: now.addingTimeInterval(-9 * 86400), isDraft: true, labels: [], commentCount: nil),
        ]
        return PullsEntry(date: now, repo: repo, configuredText: repo.slug, pulls: pulls, truncated: false,
                          fetchedAt: now.addingTimeInterval(-600), problem: nil, debug: nil)
    }
}

struct PullsProvider: AppIntentTimelineProvider {
    typealias Entry = PullsEntry
    typealias Intent = RepositoryConfiguration

    func placeholder(in context: Context) -> PullsEntry { .sample }

    /// The gallery and the transient render: the cache only, never the network.
    func snapshot(for configuration: RepositoryConfiguration, in context: Context) async -> PullsEntry {
        guard let repo = RepoRef.parse(configuration.repository) else {
            return context.isPreview ? .sample : empty(configuration)
        }
        let entry = SharedStore.loadEntry(for: repo) ?? CacheEntry(repo: repo)
        return .from(entry, includeDrafts: configuration.includeDrafts, text: configuration.repository)
    }

    /// Fetches (unless the ↻ button just did, within the last minute) and comes back in an hour.
    func timeline(for configuration: RepositoryConfiguration, in context: Context) async -> Timeline<PullsEntry> {
        let next = Date.now.addingTimeInterval(3600)
        guard let repo = RepoRef.parse(configuration.repository) else {
            return Timeline(entries: [empty(configuration)], policy: .after(next))
        }
        let entry = await RepoFetcher.refresh(repo, maxAge: 60)
        return Timeline(entries: [.from(entry, includeDrafts: configuration.includeDrafts, text: configuration.repository)], policy: .after(next))
    }

    private func empty(_ configuration: RepositoryConfiguration) -> PullsEntry {
        PullsEntry(date: .now, repo: nil, configuredText: configuration.repository, pulls: [], truncated: false,
                   fetchedAt: nil, problem: nil, debug: SharedStore.debugLogging ? SharedStore.location : nil)
    }
}

// MARK: - View

struct PullsWidgetView: View {
    let entry: PullsEntry
    @Environment(\.widgetFamily) private var family

    private let openGreen = Color(red: 0.25, green: 0.69, blue: 0.31)
    private var rowHeight: CGFloat { family == .systemMedium ? 34 : 38 }
    private var columns: Int { family == .systemExtraLarge ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            content
            footer
        }
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: Header

    private var header: some View {
        Group {
            if let repo = entry.repo {
                Link(destination: Self.openURL(repo.pullsURL)) { headerRow(repo) }
            } else {
                headerRow(nil)
            }
        }
    }

    private func headerRow(_ repo: RepoRef?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(repo?.slug ?? "PR Watch")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if repo != nil, entry.fetchedAt != nil {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 9, weight: .bold))
                    Text("Open").font(.system(size: 11, weight: .semibold))
                    Text(entry.truncated ? "\(entry.pulls.count)+" : "\(entry.pulls.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .padding(.leading, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if entry.repo == nil {
            message(systemImage: "slider.horizontal.3",
                    entry.configuredText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Edit the widget and enter a repository"
                        : "Not a repository: \(entry.configuredText)",
                    detail: "owner/name or a github.com link")
        } else if entry.pulls.isEmpty, let problem = entry.problem, entry.fetchedAt == nil {
            message(systemImage: problemSymbol(problem), problem, detail: nil)
        } else if entry.pulls.isEmpty, entry.fetchedAt == nil {
            message(systemImage: "arrow.triangle.2.circlepath", "Syncing…", detail: nil)
        } else if entry.pulls.isEmpty {
            message(systemImage: "checkmark.circle", "No open pull requests", detail: nil)
        } else {
            GeometryReader { geo in
                let perColumn = max(1, Int(geo.size.height / rowHeight))
                let capacity = perColumn * columns
                let cut = entry.pulls.count > capacity
                let shown = Array(entry.pulls.prefix(cut ? capacity - 1 : capacity))
                let perColumnShown = Int(ceil(Double(shown.count + (cut ? 1 : 0)) / Double(columns)))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<columns, id: \.self) { column in
                        let start = column * perColumnShown
                        let end = min(shown.count, start + perColumnShown)
                        VStack(alignment: .leading, spacing: 0) {
                            if start < end {
                                ForEach(shown[start..<end]) { pr in
                                    row(pr)
                                    if pr.id != shown[end - 1].id || (cut && column == columns - 1) { Divider().opacity(0.5) }
                                }
                            }
                            if cut, column == columns - 1, let repo = entry.repo {
                                Link(destination: Self.openURL(repo.pullsURL)) {
                                    Text("+\(entry.pulls.count - shown.count) more")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func row(_ pr: PullRequest) -> some View {
        Link(destination: Self.openURL(pr.htmlURL)) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(pr.isDraft ? Color.secondary : openGreen)
                    .frame(width: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(pr.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ForEach(pr.labels.prefix(3), id: \.self) { label in
                            pill(label)
                        }
                        if pr.labels.count > 3 {
                            Text("+\(pr.labels.count - 3)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    Text("#\(pr.number) · \(pr.author) opened \(RelativeTime.github(pr.createdAt, now: entry.date))\(pr.isDraft ? " · Draft" : "")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let count = pr.commentCount, count > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.right")
                        Text("\(count)").monospacedDigit()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, family == .systemMedium ? 3 : 5)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
    }

    private func pill(_ label: PRLabel) -> some View {
        let (r, g, b) = LabelColor.rgb(label.color)
        return Text(label.name)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color(red: r, green: g, blue: b)))
            .foregroundStyle(LabelColor.prefersDarkText(label.color) ? Color.black : Color.white)
            .fixedSize()
    }

    private func message(systemImage: String, _ text: String, detail: String?) -> some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: systemImage).font(.title2).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func problemSymbol(_ problem: String) -> String {
        if problem.hasPrefix("Rate limited") { return "hourglass" }
        if problem.hasPrefix("Not signed in") || problem.hasPrefix("Not authorised") { return "person.crop.circle.badge.exclamationmark" }
        if problem.hasPrefix("No connection") { return "wifi.slash" }
        return "exclamationmark.triangle"
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let debug = entry.debug {
                Text(debug).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 5) {
                if let problem = entry.problem, entry.fetchedAt != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    Text(problem).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let fetchedAt = entry.fetchedAt {
                    Text("Last synced at \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if entry.repo != nil {
                    Button(intent: RefreshIntent(repository: entry.configuredText)) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh now")
                }
            }
            .invalidatableContent()
        }
    }

    /// Clicks go through the app (`prwatch://open?url=…`), which opens the page in the default
    /// browser: WidgetKit hands every widget link to the containing app.
    static func openURL(_ target: URL) -> URL {
        var components = URLComponents()
        components.scheme = "prwatch"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: target.absoluteString)]
        return components.url ?? target
    }
}
