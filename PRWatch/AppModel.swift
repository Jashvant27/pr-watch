import Foundation
import WidgetKit

/// The app's state: who is signed in (from the keychain item and `account.json`) and the
/// repositories the widgets have cached.
@Observable
@MainActor
final class AppModel {
    var account: AccountInfo?
    var hasToken = false
    var tokenSource: String?
    var keychainProblem: String?
    var recents: [CacheEntry] = []
    var busy = false
    var message: String?
    var ghPath: String? = GhCLI.path

    func reload() {
        do {
            let stored = try TokenStore.load()
            hasToken = stored != nil
            tokenSource = stored?.source
            keychainProblem = nil
        } catch {
            hasToken = false
            tokenSource = nil
            keychainProblem = error.localizedDescription
        }
        account = SharedStore.account
        recents = SharedStore.allEntries()
        ghPath = GhCLI.path
    }

    /// Checks the token with `GET /user`, stores it and tells the widgets.
    func signIn(token rawToken: String, source: String) async {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { message = "Paste a token first."; return }
        busy = true
        defer { busy = false }
        do {
            let login = try await GitHubClient(token: token).login()
            try TokenStore.save(token: token, source: source)
            SharedStore.account = AccountInfo(login: login, source: source, checkedAt: .now)
            message = "Signed in as \(login)."
            reload()
            refreshAllWidgets()
        } catch {
            message = error.localizedDescription
        }
    }

    func useGhToken() async {
        do {
            let token = try GhCLI.token()
            await signIn(token: token, source: "gh")
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() {
        do {
            try TokenStore.delete()
            SharedStore.account = nil
            message = "Signed out. The widgets keep their last list until they refresh."
        } catch {
            message = error.localizedDescription
        }
        reload()
        refreshAllWidgets()
    }

    /// Fetches every cached repository now, then reloads every widget. A plain timeline reload
    /// would reuse a snapshot younger than a minute, so the app fetches itself first.
    func refreshAllWidgets() {
        Task {
            busy = true
            defer { busy = false }
            await RepoFetcher.refreshAll()
            reload()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Fetches one repository now (for the Refresh button in the list) and reloads its widgets.
    func refresh(_ entry: CacheEntry) async {
        busy = true
        defer { busy = false }
        let result = await RepoFetcher.refresh(entry.repo)
        if let problem = result.lastProblem { message = "\(entry.repo.slug): \(problem)" }
        reload()
        refreshAllWidgets()
    }

    func forget(_ entry: CacheEntry) {
        SharedStore.removeEntry(for: entry.repo)
        reload()
    }

    var signedInText: String {
        if let account {
            return "Signed in as \(account.login)" + (account.source == "gh" ? " (token from the gh CLI)" : "")
        }
        if hasToken { return "A token is stored" + (tokenSource == "gh" ? " (from the gh CLI)" : "") }
        return "Not signed in"
    }
}

/// Borrows the GitHub CLI's token: `gh auth token`. The app is not sandboxed, so it can run gh.
enum GhCLI {
    struct Failure: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    static var path: String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        // Last resort: the login shell's PATH.
        let output = (try? run("/bin/zsh", ["-lc", "command -v gh"])) ?? ""
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: line) ? line : nil
    }

    static func token() throws -> String {
        guard let gh = path else {
            throw Failure(text: "The gh CLI is not installed (brew install gh, then gh auth login).")
        }
        let output: String
        do {
            output = try run(gh, ["auth", "token"])
        } catch let failure as Failure {
            throw Failure(text: "gh auth token failed: \(failure.text)")
        }
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(" ") else {
            throw Failure(text: "gh is not logged in: run gh auth login in a terminal first.")
        }
        return token
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(text: text.isEmpty ? "exit status \(process.terminationStatus)" : text)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
