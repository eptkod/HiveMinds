import SwiftUI
import AppKit

/// The GitHub issue an agent was started on. Its pull request says "Fixes #number".
struct IssueRef: Codable, Hashable {
    /// owner/name
    var repo: String
    var number: Int
    var title: String
    var url: String
}

extension GitHubModel {
    struct Issue: Decodable, Identifiable, Hashable {
        struct Author: Decodable, Hashable { let login: String }
        struct Label: Decodable, Hashable { let name: String; let color: String }

        let number: Int
        var title: String
        let body: String
        let url: String
        let createdAt: Date
        let updatedAt: Date
        let author: Author?
        let labels: [Label]
        /// Filled in after decoding; gh doesn't include it per issue.
        var repo = ""
        var id: String { "\(repo)#\(number)" }

        enum CodingKeys: String, CodingKey { case number, title, body, url, createdAt, updatedAt, author, labels }

        func ref() -> IssueRef { IssueRef(repo: repo, number: number, title: title, url: url) }
    }

    /// Loads the open issues of each repository at the same time. Only runs when asked, never on a timer.
    func loadIssues(_ repos: [String]) async {
        guard let gh else { return }
        loadingIssues.formUnion(repos)
        await withTaskGroup(of: (String, Shell.Result).self) { group in
            for repo in repos {
                group.addTask {
                    (repo, await Shell.run(gh, ["issue", "list", "-R", repo, "--state", "open", "--limit", "100",
                                                "--json", "number,title,body,url,createdAt,updatedAt,author,labels"]))
                }
            }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            for await (repo, r) in group {
                loadingIssues.remove(repo)
                guard r.ok, let list = try? dec.decode([Issue].self, from: Data(r.out.utf8)) else {
                    issueErrors[repo] = "Couldn't load the issues of \(repo). \(r.message)"
                    continue
                }
                issueErrors[repo] = nil
                issues[repo] = list.map { var i = $0; i.repo = repo; return i }
            }
        }
    }

    enum CloseReason: String, CaseIterable, Identifiable {
        case completed = "completed"
        case notPlanned = "not planned"
        var id: String { rawValue }
        var label: String { self == .completed ? "Completed" : "Not planned" }
    }

    // Changes to an issue go through gh too. Each returns why it failed, or nil when it worked.

    func close(_ issue: Issue, reason: CloseReason, comment: String) async -> String? {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["--reason", reason.rawValue]
        if !comment.isEmpty { args += ["--comment", comment] }
        if let e = await issueCommand("close", issue, args, failed: "close") { return e }
        issues[issue.repo]?.removeAll { $0.number == issue.number }
        return nil
    }

    func comment(on issue: Issue, _ text: String) async -> String? {
        await issueCommand("comment", issue, ["--body", text.trimmingCharacters(in: .whitespacesAndNewlines)], failed: "comment on")
    }

    func rename(_ issue: Issue, to title: String) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = await issueCommand("edit", issue, ["--title", title], failed: "rename") { return e }
        if let i = issues[issue.repo]?.firstIndex(where: { $0.number == issue.number }) { issues[issue.repo]?[i].title = title }
        return nil
    }

    /// GitHub only lets repository admins delete issues, and it can't be undone.
    func delete(_ issue: Issue) async -> String? {
        if let e = await issueCommand("delete", issue, ["--yes"], failed: "delete") {
            return e + " Only the repository's admins can delete issues. You can close it instead."
        }
        issues[issue.repo]?.removeAll { $0.number == issue.number }
        return nil
    }

    private func issueCommand(_ command: String, _ issue: Issue, _ args: [String], failed what: String) async -> String? {
        guard let gh else { return "The GitHub CLI (gh) isn't installed." }
        let r = await Shell.run(gh, ["issue", command, "\(issue.number)", "-R", issue.repo] + args)
        return r.ok ? nil : "Couldn't \(what) #\(issue.number). \(r.message)"
    }
}

extension AppStore {
    /// Projects that are on GitHub, so they can have issues.
    var githubProjects: [Project] { shownProjects.filter { $0.repo != nil } }

    /// Agents started on this issue, newest first.
    func agents(on issue: GitHubModel.Issue) -> [Agent] {
        agents.filter { $0.issue?.repo == issue.repo && $0.issue?.number == issue.number }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Starts an agent on an issue with the defaults from Settings > Agents, in the background,
    /// so you can send several in a row without leaving the GitHub page.
    func startAgent(on issue: GitHubModel.Issue, note: String = "") async throws {
        guard let project = projects.first(where: { $0.repo == issue.repo }) else {
            throw NewAgentError("Add \(issue.repo) as a project first.")
        }
        let available = tools.providers
        let provider = available.contains(AgentDefaults.provider) ? AgentDefaults.provider : (available.first ?? .claude)
        try await createAgent(projectID: project.id, provider: provider,
                              model: provider == .claude ? AgentDefaults.model : "default",
                              planMode: AgentDefaults.planMode, role: AgentDefaults.role, task: Self.issuePrompt(issue, note: note),
                              ownBranch: AgentDefaults.ownBranch && project.isGitRepo, issue: issue.ref(), open: false)
        notice = "An agent started on #\(issue.number) in \(project.name)."
    }

    static func issuePrompt(_ issue: GitHubModel.Issue, note: String) -> String {
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = """
        Work on GitHub issue #\(issue.number) in \(issue.repo): \(issue.title)
        \(issue.url)

        \(body.isEmpty ? "(The issue has no description.)" : body)
        """
        if !note.isEmpty { text += "\n\nA note from me about this issue: \(note)" }
        text += """


        You can read the issue's comments with `gh issue view \(issue.number) --comments`. If something about it \
        is unclear, ask me rather than guessing. When you're done, commit your work with a message that ends with \
        "Fixes #\(issue.number)".
        """
        return text
    }
}

/// Open issues from your GitHub projects. Each one can be handed to an agent straight away, or with a note.
struct IssuesView: View {
    @Environment(AppStore.self) private var store
    /// Which repository to show. Nil shows every GitHub project's issues together.
    @State private var repo: String?
    @State private var search = ""

    private var gh: GitHubModel { store.github }
    private var repos: [String] { store.githubProjects.compactMap(\.repo) }
    private var shown: [String] { repo.map { [$0] } ?? repos }

    private var filtered: [GitHubModel.Issue] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return shown.flatMap { gh.issues[$0] ?? [] }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || "#\($0.number)" == q || $0.body.lowercased().contains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if repos.isEmpty {
                Card {
                    Text("Issues show up here for projects that are on GitHub. Add one under Repositories first.")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Text("Open issues").font(.headline)
                    if repos.count > 1 {
                        Picker("Project", selection: $repo) {
                            Text("All projects").tag(String?.none)
                            ForEach(store.githubProjects) { Text($0.name).tag($0.repo) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer()
                    if !gh.loadingIssues.isDisjoint(with: shown) { ProgressView().controlSize(.small) }
                    Button { Task { await gh.loadIssues(shown) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh the list")
                }
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                ForEach(shown.compactMap { gh.issueErrors[$0] }, id: \.self) {
                    Text($0).font(.callout).foregroundStyle(.red)
                }
                Card(padding: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { issue in
                            IssueRow(issue: issue, showRepo: shown.count > 1)
                            if issue.id != filtered.last?.id { Divider().padding(.leading, 16) }
                        }
                        if filtered.isEmpty && gh.loadingIssues.isDisjoint(with: shown) {
                            Text(search.isEmpty ? "No open issues." : "No issues match.").foregroundStyle(.secondary).padding(16)
                        }
                    }
                }
            }
        }
        .onAppear {
            // Start on the project you were last in, when it's on GitHub.
            if repo == nil, let id = store.currentProjectID, let r = store.project(id)?.repo, repos.count > 1 { repo = r }
        }
        .task(id: repos) {
            let missing = repos.filter { gh.issues[$0] == nil }
            if !missing.isEmpty { await gh.loadIssues(missing) }
        }
    }
}

struct IssueRow: View {
    @Environment(AppStore.self) private var store
    let issue: GitHubModel.Issue
    var showRepo = false

    @State private var expanded = false
    @State private var asking = false
    @State private var note = ""
    @State private var starting = false
    @State private var editing: Edit?
    @State private var confirmDelete = false
    @State private var busy = false

    /// The small forms the ⋯ menu opens.
    enum Edit: String, Identifiable { case close, comment, rename; var id: String { rawValue } }

    private var working: [Agent] { store.agents(on: issue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(.green)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title).fontWeight(.medium)
                    HStack(spacing: 6) {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        ForEach(issue.labels, id: \.name) { IssueLabel(label: $0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Motion.bouncy) { expanded.toggle() } }
                actions
            }
            if expanded { details.padding(.leading, 30).transition(Motion.enter) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts = ["#\(issue.number)"]
        if showRepo { parts.append(issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo) }
        parts.append("opened \(issue.createdAt.relative)" + (issue.author.map { " by @\($0.login)" } ?? ""))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if let agent = working.first {
                Button { store.select(agent.id) } label: {
                    HStack(spacing: 6) {
                        StatusDot(status: store.state(agent.id).status, size: 7)
                        Text("Open Agent")
                    }
                }
                .buttonStyle(.glass)
                .help("Go to the agent working on this issue")
            }
            if starting {
                ProgressView().controlSize(.small).frame(width: 60)
            } else {
                Button(working.isEmpty ? "Start Agent" : "Another") { start() }
                    .buttonStyle(.glassProminent)
                    .help("Start an agent on this issue now, with your defaults from Settings > Agents")
                Button { asking = true } label: { Image(systemName: "text.bubble") }
                    .buttonStyle(.glass)
                    .help("Start an agent with a note from you")
                    .popover(isPresented: $asking, arrowEdge: .bottom) { notePopover }
            }
            if busy {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                Menu {
                    Button("Close Issue…") { editing = .close }
                    Button("Add Comment…") { editing = .comment }
                    Button("Rename…") { editing = .rename }
                    Divider()
                    Button("Delete Issue…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Close, comment on, rename or delete this issue")
                .popover(item: $editing, arrowEdge: .bottom) { IssueEditForm(issue: issue, edit: $0, run: run) }
            }
        }
        .confirmationDialog("Delete #\(issue.number) \"\(issue.title)\"?", isPresented: $confirmDelete) {
            Button("Delete Issue", role: .destructive) { run { await store.github.delete(issue) } }
        } message: {
            Text("This removes the issue and its comments from GitHub for everyone, and can't be undone. Closing it keeps the history.")
        }
    }

    /// Runs a change to the issue and shows what went wrong, if anything.
    private func run(_ change: @escaping () async -> String?) {
        editing = nil
        busy = true
        Task {
            if let e = await change() { store.errorMessage = e }
            busy = false
        }
    }

    private var notePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start an agent on #\(issue.number)").font(.headline)
            TextField("Anything it should know or do differently?", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text("Your note is added after the issue's text.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { asking = false }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { asking = false; start(note: note) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(body.isEmpty ? AttributedString("No description.") : markdown(body))
                .font(.callout)
                .foregroundStyle(body.isEmpty ? .tertiary : .secondary)
                .lineLimit(14)
                .textSelection(.enabled)
            HStack(spacing: 14) {
                if let url = URL(string: issue.url) {
                    Button("View on GitHub") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                }
                if working.count > 1 {
                    Text("\(working.count) agents on this issue").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func start(note: String = "") {
        starting = true
        Task {
            do {
                try await store.startAgent(on: issue, note: note)
                self.note = ""
            } catch {
                store.errorMessage = error.localizedDescription
            }
            starting = false
        }
    }
}

/// The form behind each ⋯ menu item: closing (with a reason and an optional comment), commenting, or renaming.
private struct IssueEditForm: View {
    @Environment(AppStore.self) private var store
    let issue: GitHubModel.Issue
    let edit: IssueRow.Edit
    let run: (@escaping () async -> String?) -> Void

    @State private var text = ""
    @State private var reason = GitHubModel.CloseReason.completed

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading).font(.headline)
            if edit == .close {
                Picker("Reason", selection: $reason) {
                    ForEach(GitHubModel.CloseReason.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(edit == .rename ? 1...3 : 3...8)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text(footnote).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { run { nil } }
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) { Text(button) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(edit != .close && (trimmed.isEmpty || trimmed == issue.title))
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { if edit == .rename { text = issue.title } }
    }

    private var heading: String {
        switch edit {
        case .close: "Close #\(issue.number)"
        case .comment: "Comment on #\(issue.number)"
        case .rename: "Rename #\(issue.number)"
        }
    }

    private var placeholder: String {
        switch edit {
        case .close: "Leave a comment (optional)"
        case .comment: "Write a comment"
        case .rename: "Title"
        }
    }

    private var footnote: String {
        switch edit {
        case .close: "Anyone watching the issue is notified. You can reopen it on GitHub."
        case .comment: "Posted on GitHub as you. Markdown works."
        case .rename: "Changes the title on GitHub."
        }
    }

    private var button: String {
        switch edit {
        case .close: "Close Issue"
        case .comment: "Post Comment"
        case .rename: "Save"
        }
    }

    private func submit() {
        let gh = store.github, issue = issue, text = trimmed, reason = reason
        switch edit {
        case .close: run { await gh.close(issue, reason: reason, comment: text) }
        case .comment: run { await gh.comment(on: issue, text) }
        case .rename: run { await gh.rename(issue, to: text) }
        }
    }
}

/// A GitHub label in its own color, kept faint to suit the dark look.
struct IssueLabel: View {
    let label: GitHubModel.Issue.Label

    private var color: Color {
        guard let v = UInt32(label.color, radix: 16) else { return .secondary }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        Text(label.name)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: .capsule)
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}
