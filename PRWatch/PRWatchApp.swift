import AppKit
import SwiftUI
import WidgetKit

@main
struct PRWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onOpenURL { appDelegate.handle($0) }
        }
        .defaultSize(width: 640, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Widgets") {
                Button("Refresh All Widgets") { model.refreshAllWidgets() }
                    .keyboardShortcut("r")
                Button("Reveal Cache in Finder") {
                    if let dir = SharedStore.cacheDirectory { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The app's Settings window (Cmd+,). "Debug logging" adds a diagnostics line to the widget and
/// shows the cache path, the keychain state and each repository's last HTTP status here.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var debugLogging = SharedStore.debugLogging

    var body: some View {
        Form {
            Toggle("Debug logging", isOn: $debugLogging)
                .onChange(of: debugLogging) { _, on in
                    SharedStore.debugLogging = on
                    WidgetCenter.shared.reloadAllTimelines()
                }
            Text("Shows where the cache is, whether the token can be read, and each widget's last HTTP status and remaining GitHub rate limit, here and at the bottom of every widget.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if debugLogging {
                Divider()
                Group {
                    Text("Cache: \(SharedStore.location)")
                    Text("Token: \(TokenStore.diagnostics)")
                    ForEach(model.recents, id: \.repo) { entry in
                        Text("\(entry.repo.slug): status \(entry.lastStatus.map(String.init) ?? "–")"
                             + (entry.rateLimitRemaining.map { " · rate limit remaining \($0)" } ?? "")
                             + (entry.rateLimitReset.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
                             + (entry.lastProblem.map { " · \($0)" } ?? ""))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.reload() }
    }
}

extension Notification.Name {
    /// Posted after `prwatch://refresh` fetched the repositories, so an open window reloads its list.
    static let widgetsRefreshed = Notification.Name("widgetsRefreshed")
}

/// Opens widget links in the browser and quits when the last window closes, like the system
/// widgets' companion apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchedAt = Date()
    private var finishedLaunching = false
    private var lastHandled: (URL, Date)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Catches the launch URL before SwiftUI opens the window, so a click on a PR in the widget
        // opens the browser without the app's window flashing up.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:with:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        handle(url)
    }

    /// `prwatch://open?url=https://github.com/…` opens that GitHub page in the default browser;
    /// `prwatch://refresh` fetches every cached repository and reloads every widget (what
    /// `Scripts/refresh-widgets.sh` sends after a PR is opened or merged). When the app was
    /// launched only for the URL it quits again afterwards. The same URL can arrive through more
    /// than one of the three routes (Apple event, delegate, onOpenURL), so it is handled once.
    func handle(_ url: URL) {
        guard url.scheme == "prwatch" else { return }
        if let (previous, at) = lastHandled, previous == url, Date().timeIntervalSince(at) < 2 { return }
        lastHandled = (url, Date())
        switch url.host {
        case "open":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let text = items.first(where: { $0.name == "url" })?.value, let target = URL(string: text),
                  target.scheme == "https", let host = target.host?.lowercased(),
                  host == "github.com" || host.hasSuffix(".github.com") else { return }
            let launchedForThis = !finishedLaunching || Date().timeIntervalSince(launchedAt) < 2
            NSWorkspace.shared.open(target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                // Launched only to open the page: leave again without showing the window.
                if launchedForThis { DispatchQueue.main.async { exit(0) } }
            }
        case "refresh":
            let launchedForThis = !finishedLaunching || Date().timeIntervalSince(launchedAt) < 2
            Task { @MainActor in
                await RepoFetcher.refreshAll()
                WidgetCenter.shared.reloadAllTimelines()
                NotificationCenter.default.post(name: .widgetsRefreshed, object: nil)
                // Give the reload request a moment to reach WidgetKit before leaving.
                if launchedForThis { try? await Task.sleep(for: .seconds(1)); exit(0) }
            }
        default:
            break
        }
    }
}
