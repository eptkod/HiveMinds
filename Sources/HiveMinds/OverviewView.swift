import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store

    private var sorted: [Agent] {
        store.workspaceAgents.sorted {
            let a = store.state($0.id), b = store.state($1.id)
            return a.status.rank != b.status.rank ? a.status.rank < b.status.rank : a.updated > b.updated
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Overview", subtitle: store.workspaceAgents.isEmpty ? nil : summary)
                if !store.spend.allHistory.isEmpty {
                    OverviewStats()
                }
                if store.workspaceAgents.isEmpty {
                    EmptyOverview()
                } else {
                    if !store.spend.allHistory.isEmpty {
                        Text("Agents").font(.title3.weight(.semibold)).padding(.top, 8)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(sorted) { AgentCard(agent: $0) }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
    }

    private var summary: String {
        let counts = Dictionary(grouping: store.workspaceAgents) { store.state($0.id).status }.mapValues(\.count)
        let parts: [(AgentStatus, String)] = [(.needsYou, "need you"), (.working, "working"), (.done, "done"), (.idle, "ready"), (.asleep, "asleep")]
        return parts.compactMap { s, word in counts[s].map { "\($0) \(word)" } }.joined(separator: " · ")
    }
}

/// One agent on the Overview: what it's doing, in an icon and a line, its glow in its status colour, and
/// what it's built up so far (its week of tokens, cost and line changes) along the bottom.
struct AgentCard: View {
    @Environment(AppStore.self) private var store
    let agent: Agent
    @State private var hovering = false

    var body: some View {
        let s = store.state(agent.id)
        let tint = s.status == .asleep ? Color.secondary : s.status.color
        Button { store.select(agent.id) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ActivityIcon(symbol: Self.symbol(for: s), tint: tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.title).font(.headline).lineLimit(1).help(agent.title)
                        HStack(spacing: 5) {
                            Text(store.project(agent.projectID)?.name ?? "")
                            if let b = agent.branch {
                                Image(systemName: "arrow.triangle.branch").imageScale(.small)
                                Text(b).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    StatusPill(status: s.status)
                }

                Text(s.activity.isEmpty ? "Nothing yet" : s.activity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.7)).frame(width: 2).padding(.vertical, 9)
                    }

                chips

                HStack(alignment: .bottom, spacing: 10) {
                    WeekSparkline(history: store.spend.histories[agent.id], tint: tint)
                    TokenBadge(agents: [agent.id])
                    Spacer(minLength: 4)
                    ChangesButton(agent: agent)
                    Text(s.updated.relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
                // A soft wash of the status colour from the top corner, so the grid reads at a glance.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [tint.opacity(s.status == .asleep ? 0.04 : 0.14), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: 260))
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(border(s.status), lineWidth: s.status == .needsYou ? 1 : 0.5))
            .scaleEffect(hovering ? 1.012 : 1)
            .animation(Motion.press, value: hovering)
            .animation(Motion.bouncy, value: s.status)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Model and effort, plus its pull request and issue when it has them.
    @ViewBuilder private var chips: some View {
        let model = agent.model == "default" ? agent.provider.label : agent.model.capitalized
        HStack(spacing: 6) {
            Chip(icon: "cpu", text: agent.effort.map { "\(model) · \($0.label)" } ?? model)
            if let pr = agent.pullRequest {
                Chip(icon: "arrow.triangle.pull", text: "#\(pr.number) \(pr.label)",
                     tint: pr.state == "MERGED" ? .purple : pr.state == "OPEN" ? .green : nil)
            }
            if let issue = agent.issue {
                Chip(icon: "smallcircle.filled.circle", text: "#\(issue.number)")
                    .help(issue.title)
            }
        }
    }

    private func border(_ status: AgentStatus) -> Color {
        if status == .needsYou { return .orange.opacity(0.6) }
        return hovering ? Color.white.opacity(0.18) : Theme.hairline
    }

    /// A picture of what the agent is doing, read from its activity line.
    static func symbol(for s: LiveState) -> String {
        switch s.status {
        case .asleep: return "moon.zzz"
        case .starting: return "power"
        case .needsYou: return "hand.raised"
        case .done: return "checkmark"
        case .idle: return "text.cursor"
        case .working: break
        }
        let a = s.activity
        let starts: [(String, String)] = [
            ("Running", "terminal"), ("Reading", "doc.text"), ("Editing", "pencil"), ("Writing", "square.and.pencil"),
            ("Searching", "magnifyingglass"), ("Looking something up", "globe"), ("Handing part", "person.2"),
            ("Planning", "checklist"), ("Asked", "text.bubble"), ("Thinking", "sparkles"),
        ]
        return starts.first { a.hasPrefix($0.0) }?.1 ?? "sparkles"
    }
}

/// The rounded tile at the top left of an agent card, tinted with its status.
private struct ActivityIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

/// A small label with an icon, for facts about an agent.
private struct Chip: View {
    let icon: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((tint ?? .white).opacity(0.07), in: .capsule)
    }
}

/// The agent's last seven days of tokens as tiny bars, today on the right in its status colour.
private struct WeekSparkline: View {
    let history: UsageHistory?
    let tint: Color

    var body: some View {
        if let history, !history.isEmpty {
            let cal = Calendar.current
            let today = Date()
            let values = (0..<7).reversed().map { back in
                cal.date(byAdding: .day, value: -back, to: today).map { history.day($0).tokens } ?? 0
            }
            let top = max(values.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == values.count - 1 ? tint : Color.white.opacity(0.22))
                        .frame(width: 3, height: max(2, 16 * CGFloat(values[i]) / CGFloat(top)))
                }
            }
            .frame(height: 16, alignment: .bottom)
            .help("Tokens over the last 7 days")
        }
    }
}

struct EmptyOverview: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Card(padding: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.shownProjects.isEmpty ? "Start with a project" : "No agents yet")
                    .font(.title3.weight(.semibold))
                Text(store.shownProjects.isEmpty
                     ? "A project is a folder your agents work in, usually one of your GitHub repositories."
                     : "An agent is a Claude Code chat that works in your project and tells you when it needs you.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if store.shownProjects.isEmpty {
                        Button("Add from GitHub") { store.mode = .github }
                            .buttonStyle(.glassProminent)
                        Button("Add a Folder…") { store.chooseLocalFolder() }
                            .buttonStyle(.glass)
                    } else {
                        Button("New Agent") { store.beginNewAgent(in: nil) }
                            .buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}
