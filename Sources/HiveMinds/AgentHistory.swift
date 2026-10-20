import SwiftUI

/// An agent that was deleted, kept so the History page can still show it.
struct PastAgent: Codable, Identifiable, Hashable {
    var agent: Agent
    var projectName: String
    /// The meeting it sat in, by title, if it was a meeting seat.
    var meetingTitle: String?
    var endedAt = Date()
    var cost = 0.0
    var tokens = 0
    var id: UUID { agent.id }
}

/// Deleted agents, newest first. To keep it small, it holds at most the number set in Settings > Agents,
/// and each one goes once it's older than the days set there. Trimming happens when something is added and
/// when the page opens, so nothing runs in the background.
@MainActor @Observable
final class AgentHistoryModel {
    private(set) var entries: [PastAgent] = []
    private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([PastAgent].self, from: data) {
            entries = saved
        }
        trim()
    }

    func record(_ past: [PastAgent]) {
        guard !past.isEmpty else { return }
        entries.insert(contentsOf: past.sorted { $0.endedAt > $1.endedAt }, at: 0)
        trim(force: true)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Drops what's past the age or count limit. Saves only if something changed, unless `force`.
    func trim(force: Bool = false) {
        let cutoff = Date().addingTimeInterval(-Double(AgentDefaults.historyDays) * 86_400)
        let before = entries.count
        entries.removeAll { $0.endedAt < cutoff }
        if entries.count > AgentDefaults.historyLimit { entries.removeLast(entries.count - AgentDefaults.historyLimit) }
        if force || entries.count != before { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}

extension AppStore {
    /// Snapshots agents that are about to be deleted, with what they used, for the History page.
    /// Call it before `spend.forget`, which drops their cost.
    func remember(_ gone: [Agent]) {
        history.record(gone.map { a in
            PastAgent(agent: a, projectName: project(a.projectID)?.name ?? "Removed project",
                      meetingTitle: a.meetingID.flatMap { meeting($0)?.title },
                      cost: spend.cost(for: [a.id]), tokens: spend.tokens(for: [a.id]).total)
        })
    }

    /// Why a past agent can't come back, or nil if it can.
    func cantBringBack(_ past: PastAgent) -> String? {
        if past.agent.provider != .claude { return "Only Claude Code chats can be picked up again." }
        if project(past.agent.projectID) == nil { return "Its project isn't in HiveMinds any more." }
        if agent(past.id) != nil { return "It's already back." }
        return nil
    }

    /// Recreates a deleted Claude Code agent, which resumes its old conversation. If its own folder was removed,
    /// it's made again from its branch, since Claude Code keeps sessions per folder.
    func bringBack(_ past: PastAgent) async {
        guard cantBringBack(past) == nil, let project = project(past.agent.projectID) else { return }
        var agent = past.agent
        agent.meetingID = nil
        agent.pendingTask = nil
        if !FileManager.default.fileExists(atPath: agent.cwd) {
            guard let branch = agent.branch, let git = tools.git else {
                errorMessage = "Couldn't bring back \"\(agent.title)\": its folder \(agent.cwd) is gone."
                return
            }
            let r = await Shell.run(git, ["-C", project.path, "worktree", "add", agent.cwd, branch])
            guard r.ok else {
                errorMessage = "Couldn't bring back \"\(agent.title)\": its branch \(branch) couldn't be checked out again. \(r.message)"
                return
            }
        }
        agents.append(agent)
        live[agent.id] = LiveState(status: .starting, activity: "Starting up")
        history.remove(agent.id)
        save()
        spend.watch(agent.id)
        select(agent.id)
    }
}

/// Every agent: the ones you have now, then the ones you deleted, newest first.
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var confirmClear = false
    @AppStorage(SettingKey.historyDays) private var days = SettingDefault.historyDays
    @AppStorage(SettingKey.historyLimit) private var limit = SettingDefault.historyLimit

    private func matches(_ a: Agent, _ project: String) -> Bool {
        search.isEmpty || a.title.localizedCaseInsensitiveContains(search) || project.localizedCaseInsensitiveContains(search)
            || (a.branch ?? "").localizedCaseInsensitiveContains(search)
    }

    private var current: [Agent] {
        store.agents.filter { matches($0, store.project($0.projectID)?.name ?? "") }.sorted { $0.createdAt > $1.createdAt }
    }

    private var past: [PastAgent] { store.history.entries.filter { matches($0.agent, $0.projectName) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    PageHeader(title: "History",
                               subtitle: "Every agent. Deleted ones are kept for \(days) \(days == 1 ? "day" : "days"), up to \(limit) of them.")
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                section("Now", count: current.count) {
                    ForEach(current) { a in
                        HistoryRow(agent: a, project: store.project(a.projectID)?.name ?? "",
                                   detail: "Started \(a.createdAt.relative)", status: store.state(a.id).status) {
                            store.select(a.id)
                        }
                    }
                }
                section("Deleted", count: past.count) {
                    ForEach(past) { p in
                        HistoryRow(agent: p.agent, project: p.meetingTitle.map { "\(p.projectName) · \($0)" } ?? p.projectName,
                                   detail: "Deleted \(p.endedAt.relative)" + (p.cost > 0 ? " · \(TokenBadge.money(p.cost))" : ""),
                                   status: nil, open: nil)
                            .contextMenu { PastAgentMenu(past: p) }
                    }
                }
                if !store.history.entries.isEmpty {
                    Button("Clear History…") { confirmClear = true }
                        .buttonStyle(.glass)
                }
            }
            .padding(32)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .onAppear { store.history.trim() }
        .confirmationDialog("Clear the history of deleted agents?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.history.clear() }
        } message: {
            Text("Agents you have now stay. Their conversations remain in Claude Code; only this list is cleared.")
        }
    }

    @ViewBuilder private func section<Rows: View>(_ title: String, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            if count == 0 {
                Text(search.isEmpty ? "None." : "Nothing matches.").foregroundStyle(.secondary)
            } else {
                Card(padding: 6) { LazyVStack(spacing: 0) { rows() } }
            }
        }
    }
}

private struct HistoryRow: View {
    let agent: Agent
    let project: String
    let detail: String
    /// Nil for a deleted agent.
    let status: AgentStatus?
    let open: (() -> Void)?

    var body: some View {
        Button { open?() } label: {
            HStack(spacing: 12) {
                if let status { StatusDot(status: status) } else {
                    Image(systemName: "archivebox").font(.caption).foregroundStyle(.tertiary).frame(width: 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.title).fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(project)
                        if let b = agent.branch { Text("·"); Text(b).lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Text(agent.model == "default" ? agent.provider.label : "\(agent.provider.label) · \(agent.model.capitalized)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PastAgentMenu: View {
    @Environment(AppStore.self) private var store
    let past: PastAgent

    var body: some View {
        let reason = store.cantBringBack(past)
        Button("Bring Back") { Task { await store.bringBack(past) } }
            .disabled(reason != nil)
            .help(reason ?? "Starts it again in the same conversation.")
        if let branch = past.agent.branch {
            Button("Copy Branch Name") { copy(branch) }
        }
        if past.agent.provider == .claude {
            Button("Copy Resume Command") { copy("claude --resume \(past.agent.sessionID.uuidString.lowercased())") }
        }
        Divider()
        Button("Remove from History", role: .destructive) { store.history.remove(past.id) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
