import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(SettingKey.showUsage) private var showUsage = SettingDefault.showUsage
    /// The project whose rows are dropping in, and how many of them have dropped so far. The list builds
    /// its rows lazily, so they read this when they're built instead of deciding on their own.
    @State private var dropping: UUID?
    @State private var dropped = 0

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(SidebarItem.overview)

            ForEach(store.projects) { project in
                Section {
                    // A project's agents only show while its workspace is open, to keep the sidebar short.
                    let open = store.currentProjectID == project.id
                    CanvasRow(agents: store.agents(in: project), expanded: open)
                        .tag(SidebarItem.project(project.id))
                    if open {
                        let agents = store.agents(in: project)
                        ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                            AgentRow(agent: agent)
                                .modifier(ChainDrop(shown: dropping != project.id || i < dropped))
                                .tag(SidebarItem.agent(agent.id))
                                .contextMenu { AgentMenu(agent: agent) }
                        }
                        Button { store.beginNewAgent(in: project.id) } label: {
                            Label("New agent", systemImage: "plus")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .modifier(ChainDrop(shown: dropping != project.id || agents.count < dropped))
                    }
                } header: {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Menu {
                            Button("New Agent Here") { store.beginNewAgent(in: project.id) }
                            Button("New Browser Tab") { store.newBrowserTab(in: project.id) }
                            Button("New Shell Tab") { store.newShellTab(in: project.id) }
                            Button("Show in Finder") { store.revealInFinder(project.path) }
                            if let repo = project.repo, let url = URL(string: "https://github.com/\(repo)") {
                                Link("Open on GitHub", destination: url)
                            }
                            Divider()
                            Button("Remove from HiveMinds", role: .destructive) { store.removeProject(project) }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        // Line the button up with the rows' trailing edge instead of the sidebar's edge.
                        .padding(.trailing, 8)
                        .help("Project options. Removing it from HiveMinds doesn't delete any files.")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.2), value: store.currentProjectID)
        .onChange(of: store.currentProjectID) { old, new in
            guard let new, new != old, let project = store.project(new) else { return }
            dropIn(project)
        }
        .onChange(of: store.selection) { _, _ in store.mode = .agents }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if showUsage && store.tools.claude != nil {
                    UsageMeter().padding(.horizontal, 12)
                }
                bottomBar
            }
        }
    }

    /// Drops a project's rows in one after another, each with its own springy animation.
    private func dropIn(_ project: Project) {
        dropping = project.id
        dropped = 0
        let rows = store.agents(in: project).count + 1
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            for _ in 0..<rows {
                guard dropping == project.id else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) { dropped += 1 }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if dropping == project.id { dropping = nil }
        }
    }

    private var bottomBar: some View {
        Menu {
            Button("From GitHub…") { store.mode = .github }
            Button("Folder on This Mac…") { store.chooseLocalFolder() }
        } label: {
            Label("Add Project", systemImage: "folder.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// A project's Canvas row. While the project is collapsed it shows how many agents are tucked under it,
/// and an orange dot if any of them needs you.
struct CanvasRow: View {
    @Environment(AppStore.self) private var store
    let agents: [Agent]
    let expanded: Bool

    var body: some View {
        HStack {
            Label("Canvas", systemImage: "square.grid.2x2")
            Spacer()
            if !expanded && !agents.isEmpty {
                if agents.contains(where: { store.state($0.id).status == .needsYou }) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                Text("\(agents.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Rows under a project's Canvas drop in one after another with a little bounce when it opens.
struct ChainDrop: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -14)
            .scaleEffect(shown ? 1 : 0.96, anchor: .top)
    }
}

struct AgentRow: View {
    @Environment(AppStore.self) private var store
    let agent: Agent

    var body: some View {
        let s = store.state(agent.id)
        HStack(spacing: 10) {
            StatusDot(status: s.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title).fontWeight(.medium).lineLimit(1)
                Text(s.activity.isEmpty ? s.status.label : s.activity)
                    .font(.caption)
                    .foregroundStyle(s.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
