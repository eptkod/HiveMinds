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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
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

struct AgentCard: View {
    @Environment(AppStore.self) private var store
    let agent: Agent

    var body: some View {
        let s = store.state(agent.id)
        Button { store.select(agent.id) } label: {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(agent.title).font(.headline).lineLimit(1)
                        Spacer()
                        StatusPill(status: s.status)
                    }
                    Text(s.activity.isEmpty ? "Nothing yet" : s.activity)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(store.project(agent.projectID)?.name ?? "")
                        if let b = agent.branch { Text("·"); Text(b).lineLimit(1) }
                        Spacer()
                        Text(s.updated.relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(s.status == .needsYou ? 0.6 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct EmptyOverview: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Card(padding: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.projects.isEmpty ? "Start with a project" : "No agents yet")
                    .font(.title3.weight(.semibold))
                Text(store.projects.isEmpty
                     ? "A project is a folder your agents work in, usually one of your GitHub repositories."
                     : "An agent is a Claude Code chat that works in your project and tells you when it needs you.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if store.projects.isEmpty {
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
