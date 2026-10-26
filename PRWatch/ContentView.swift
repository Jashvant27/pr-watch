import AppKit
import SwiftUI

/// One window: the GitHub account, the repositories the widgets have cached, and refresh.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var showTokenField = false

    var body: some View {
        @Bindable var model = model
        Form {
            accountSection
            repositoriesSection
            widgetsSection
        }
        .formStyle(.grouped)
        .navigationTitle("PR Watch")
        .task { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .widgetsRefreshed)) { _ in
            model.reload()
        }
        .alert("PR Watch", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section("GitHub account") {
            HStack {
                Image(systemName: model.hasToken ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    .foregroundStyle(model.hasToken ? Color.green : Color.secondary)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.signedInText).font(.headline)
                    if let account = model.account {
                        Text("Checked \(account.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.hasToken {
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
            }
            if let problem = model.keychainProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if !model.hasToken || showTokenField {
                SecureField("Personal access token (ghp_… or github_pat_…)", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                HStack {
                    Button("Save token") { save() }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                        .keyboardShortcut(.defaultAction)
                    Button("Use gh CLI token") { Task { await model.useGhToken() } }
                        .disabled(model.busy)
                        .help(model.ghPath.map { "Runs \($0) auth token" } ?? "gh is not installed")
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("A classic token with the `repo` scope, or a fine-grained token with read access to Pull requests on the repositories you watch (organisation repositories need the organisation selected as resource owner). The token is checked with GET /user and kept in your keychain, where the widget reads it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("Replace token…") { showTokenField = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private func save() {
        let value = token
        token = ""
        showTokenField = false
        Task { await model.signIn(token: value, source: "pasted") }
    }

    // MARK: Repositories

    private var repositoriesSection: some View {
        Section {
            if model.recents.isEmpty {
                Text("No repository has been synced yet. Add a widget and enter a repository (see below); it appears here after its first sync.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.recents, id: \.repo) { entry in
                repositoryRow(entry)
            }
        } header: {
            Text("Recent repositories")
        } footer: {
            Text("The repositories your widgets have fetched, from their cache files. macOS does not tell the app which widgets are on the desktop, so a repository stays here until you forget it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func repositoryRow(_ entry: CacheEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "book.closed").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.repo.slug).font(.headline)
                HStack(spacing: 6) {
                    if let snapshot = entry.snapshot {
                        let drafts = snapshot.pulls.filter(\.isDraft).count
                        Text("\(snapshot.pulls.count)\(snapshot.truncated ? "+" : "") open" + (drafts > 0 ? " (\(drafts) draft\(drafts == 1 ? "" : "s"))" : ""))
                        Text("·")
                        Text("last synced \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("never synced")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let problem = entry.lastProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(entry.repo.pullsURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open the pull requests on GitHub")
            Button {
                Task { await model.refresh(entry) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.busy)
            .help("Fetch now and refresh the widgets")
            Menu {
                Button("Forget", role: .destructive) { model.forget(entry) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open on GitHub") { NSWorkspace.shared.open(entry.repo.pullsURL) }
            Button("Refresh") { Task { await model.refresh(entry) } }
            Divider()
            Button("Forget", role: .destructive) { model.forget(entry) }
        }
    }

    // MARK: Widgets

    private var widgetsSection: some View {
        Section("Widgets") {
            HStack {
                Button("Refresh all widgets") { model.refreshAllWidgets() }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a widget").font(.subheadline.weight(.semibold))
                Text("1. Click the desktop (or the clock in the menu bar) and choose Edit Widgets.\n2. Search for PR Watch and drag out a size: Medium shows 2 pull requests, Large about 6, Extra Large about 12.\n3. Right-click the widget → Edit Widget, paste the repository (owner/name or its GitHub link) and press Done.\n\nEvery widget refreshes about every hour; the ↻ in its footer refreshes it now. Click a pull request to open it in your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}
