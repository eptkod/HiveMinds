import SwiftUI

struct GitHubView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var confirmDisconnect = false
    @AppStorage(SettingKey.githubTab) private var tab = Tab.repositories

    enum Tab: String, CaseIterable, Identifiable {
        case repositories = "Repositories", issues = "Issues"
        var id: String { rawValue }
    }

    private var gh: GitHubModel { store.github }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "GitHub", subtitle: "Connect once, then pick the repositories your agents work on, and hand their issues to agents. Agents can commit, open pull requests and publish releases.")
                connection
                if let error = gh.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if gh.login != nil {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    switch tab {
                    case .repositories: repos
                    case .issues: IssuesView()
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Disconnect GitHub?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await gh.disconnect() } }
        } message: {
            Text("This signs the GitHub CLI out on this Mac, which also affects other apps that use it, such as Agent Office.")
        }
    }

    @ViewBuilder private var connection: some View {
        Card {
            switch gh.phase {
            case .checking:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking your GitHub connection…") }
            case .missing:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Install the GitHub tool first").font(.headline)
                    Text("HiveMinds connects to GitHub through GitHub's own command-line tool. Paste this into Terminal, then come back.")
                        .foregroundStyle(.secondary)
                    Text("brew install gh").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Check Again") { Task { await store.recheckTools() } }.buttonStyle(.glass)
                }
            case .signedOut:
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not connected").font(.headline)
                        Text("You'll approve HiveMinds in your browser. No passwords or tokens to copy.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect GitHub") { gh.connect() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            case .signingIn(let code):
                VStack(alignment: .leading, spacing: 14) {
                    if let code {
                        Text("Enter this code on GitHub").font(.headline)
                        Text(code)
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button("Copy Code and Open GitHub") { gh.copyCodeAndOpen(code) }
                                .buttonStyle(.glassProminent)
                            Button("Cancel") { gh.cancelSignIn() }
                                .buttonStyle(.glass)
                            ProgressView().controlSize(.small).padding(.leading, 6)
                            Text("Waiting for you to approve…").foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Asking GitHub for a code…") }
                    }
                }
            case .connected(let login):
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected as @\(login)").font(.headline)
                        Text("Signed in through the GitHub CLI. The sign-in is kept in your Mac's Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") { confirmDisconnect = true }.buttonStyle(.glass)
                }
            }
        }
    }

    private var filtered: [GitHubModel.Repo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? gh.repos : gh.repos.filter { $0.nameWithOwner.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
    }

    private var repos: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your repositories").font(.headline)
                Spacer()
                if gh.loadingRepos { ProgressView().controlSize(.small) }
                Button { Task { await gh.loadRepos() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the list")
            }
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            Card(padding: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { repo in
                        RepoRow(repo: repo)
                        if repo.id != filtered.last?.id { Divider().padding(.leading, 16) }
                    }
                    if filtered.isEmpty && !gh.loadingRepos {
                        Text("No repositories found.").foregroundStyle(.secondary).padding(16)
                    }
                }
            }
        }
    }
}

struct RepoRow: View {
    @Environment(AppStore.self) private var store
    let repo: GitHubModel.Repo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.nameWithOwner).fontWeight(.medium)
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let pushed = repo.pushedAt {
                Text(pushed.relative).font(.caption).foregroundStyle(.tertiary)
            }
            // A fixed-width slot, so the dates line up whatever state each repository is in.
            Group {
                if store.hasProject(repo: repo.nameWithOwner) {
                    Label("Added", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(.secondary).font(.callout)
                } else if store.github.cloning.contains(repo.nameWithOwner) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add") { Task { await store.addRepo(repo.nameWithOwner) } }
                        .buttonStyle(.glass)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
