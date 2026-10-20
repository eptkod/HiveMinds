import SwiftUI

/// A project's workspace: a row of tabs (the Canvas with everything at once, each agent, and any browser or shell tabs)
/// over whichever tab is open. Picking a project or one of its agents in the sidebar opens it.
struct WorkspaceView: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabBar(project: project)
            Group {
                switch store.selection {
                case .agent(let id) where store.agent(id) != nil:
                    AgentDetailView(agent: store.agent(id)!)
                        .id(id)
                case .browser(let id) where store.browserTab(id) != nil:
                    BrowserView(tab: store.browserTab(id)!)
                        .id(id)
                case .shell(let id) where store.shellTab(id) != nil:
                    ShellView(tab: store.shellTab(id)!)
                        .id(id)
                case .meeting(let id) where store.meeting(id) != nil:
                    MeetingOverviewPage(meeting: store.meeting(id)!)
                        .id(id)
                default:
                    CanvasView(project: project)
                }
            }
            .transition(Motion.enter)
        }
        // Every way of changing tabs (sidebar, tab row, shortcuts) gets the same spring.
        .animation(Motion.bouncy, value: store.selection)
    }
}

struct WorkspaceTabBar: View {
    @Environment(AppStore.self) private var store
    let project: Project
    /// Shared by the tabs so the open tab's glass slides from one tab to the next.
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 4) {
                        WorkspaceTab(selected: !isAgentOrBrowser, namespace: selection, help: "Every agent, browser tab, shell and meeting in \(project.name), side by side") {
                            Image(systemName: "square.grid.2x2")
                            Text("Canvas")
                        } action: {
                            store.selection = .project(project.id)
                        }
                        ForEach(store.agents(in: project)) { agent in
                            WorkspaceTab(selected: store.selection == .agent(agent.id), namespace: selection, help: store.state(agent.id).activity) {
                                StatusDot(status: store.state(agent.id).status, size: 7)
                                Text(agent.title)
                            } action: {
                                store.selection = .agent(agent.id)
                            }
                            .contextMenu { AgentMenu(agent: agent) }
                        }
                        ForEach(store.browserTabs(in: project)) { tab in
                            WorkspaceTab(selected: store.selection == .browser(tab.id), namespace: selection, help: tab.url,
                                         close: { store.closeBrowserTab(tab.id) }) {
                                Image(systemName: "globe")
                                Text(browserTitle(tab))
                            } action: {
                                store.selection = .browser(tab.id)
                            }
                        }
                        ForEach(store.shellTabs(in: project)) { tab in
                            WorkspaceTab(selected: store.selection == .shell(tab.id), namespace: selection, help: "A shell in \(project.name)",
                                         close: { store.closeShellTab(tab.id) }) {
                                Image(systemName: "terminal")
                                Text(shellTitle(tab))
                            } action: {
                                store.selection = .shell(tab.id)
                            }
                        }
                        ForEach(store.canvasMeetings(in: project)) { meeting in
                            WorkspaceTab(selected: store.selection == .meeting(meeting.id), namespace: selection,
                                         help: "\(meeting.pattern.name) · \(meetingProgress(meeting))",
                                         close: { store.hideMeetingFromCanvas(meeting.id) }) {
                                Image(systemName: meeting.pattern.symbol)
                                Text(meeting.title)
                            } action: {
                                store.selection = .meeting(meeting.id)
                            }
                            .contextMenu {
                                Button("Open Meeting Room") { store.openMeeting(meeting.id) }
                                Button("Take Off the Canvas") { store.hideMeetingFromCanvas(meeting.id) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollClipDisabled()
            // Clipped at the sides only, so tabs don't run under the total and the + while the glass
            // can still spill above and below.
            .mask(Rectangle().padding(.vertical, -20))

            // The project's total, while the Canvas is open. Each agent's own tab shows its own.
            if !isAgentOrBrowser {
                TokenBadge(agents: store.agents.filter { $0.projectID == project.id }.map(\.id), scope: "every agent in this project")
                Button {
                    withAnimation(Motion.bouncy) {
                        store.pinCanvas(in: project, [:])
                        store.groupCanvas(in: project, [:])
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.canvasPins[project.id, default: [:]].isEmpty && store.canvasGroups[project.id, default: [:]].isEmpty)
                .help("Put every tile back to its automatic size and place")
            }

            Menu {
                Button("New Agent") { store.beginNewAgent(in: project.id) }
                Button("New Browser Tab") { store.newBrowserTab(in: project.id) }
                Button("New Shell Tab") { store.newShellTab(in: project.id) }
                Button("New Meeting…") { store.beginNewMeeting() }
                    .disabled(store.tools.claude == nil)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open a new tab")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var isAgentOrBrowser: Bool {
        switch store.selection {
        case .agent, .browser, .shell, .meeting: true
        default: false
        }
    }

    private func shellTitle(_ tab: ShellTab) -> String {
        let title = Shells.shared.existing(tab.id)?.title ?? ""
        return title.isEmpty ? "Shell" : title
    }

    private func browserTitle(_ tab: BrowserTab) -> String {
        let title = Browsers.existing(tab.id)?.title ?? tab.title
        if !title.isEmpty { return title }
        return URL(string: tab.url)?.host() ?? "New tab"
    }
}

/// One tab in the workspace's tab row. The open tab sits on glass; the rest are plain.
/// There's only one piece of glass, and it springs over to whichever tab you open.
struct WorkspaceTab<Label: View>: View {
    let selected: Bool
    let namespace: Namespace.ID
    var help = ""
    var close: (() -> Void)?
    @ViewBuilder let label: Label
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 6) { label }
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.squish)
            if let close {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(selected || hovering ? 1 : 0)
                    .help("Close tab")
            }
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering && !selected ? Theme.surface : .clear, in: Capsule())
        // The glass goes on the tab itself, not in a background: the container draws background glass
        // on top of the label, which washed the open tab's text out.
        .modifier(SelectedTabGlass(selected: selected, namespace: namespace))
        .animation(Motion.press, value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Puts the open tab on glass. Sharing one glass ID lets the container morph it from tab to tab.
private struct SelectedTabGlass: ViewModifier {
    let selected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if selected {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("selected-tab", in: namespace)
        } else {
            content
        }
    }
}

// MARK: Canvas

/// Everything open in the project at once: each agent in a live terminal, and each browser tab as a
/// live page, all of which you can use in place.
struct CanvasView: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let items = store.canvasItems(in: project)
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: project.name, subtitle: "Your agents, browser tabs and shells in this project show here side by side.")
                Card(padding: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Nothing open yet").font(.title3.weight(.semibold))
                        Text("An agent is a Claude Code chat that works in this project and tells you when it needs you. A browser tab is handy for watching what it builds.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("New Agent") { store.beginNewAgent(in: project.id) }
                                .buttonStyle(.glassProminent)
                            Button("New Browser Tab") { store.newBrowserTab(in: project.id) }
                                .buttonStyle(.glass)
                            Button("New Shell Tab") { store.newShellTab(in: project.id) }
                                .buttonStyle(.glass)
                        }
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                Spacer()
            }
            .padding(32)
        } else {
            TileGrid(items: items, pins: store.canvasPins[project.id] ?? [:],
                     onReorder: { store.reorderCanvas(in: project.id, $0) },
                     onPin: { store.pinCanvas(in: project, $0) },
                     groups: store.canvasGroups[project.id] ?? [:],
                     onGroup: { store.groupCanvas(in: project, $0) }) { id, isDragged, drag in
                if let agent = store.agent(id) {
                    AgentTile(agent: agent, isDragged: isDragged, drag: drag)
                } else if let tab = store.browserTab(id) {
                    BrowserTile(tab: tab, isDragged: isDragged, drag: drag)
                } else if let tab = store.shellTab(id) {
                    ShellTile(tab: tab, isDragged: isDragged, drag: drag)
                } else if let meeting = store.meeting(id) {
                    MeetingTile(meeting: meeting, isDragged: isDragged, drag: drag)
                }
            }
        }
    }
}

struct AgentTile<Drag: Gesture>: View {
    @Environment(AppStore.self) private var store
    let agent: Agent
    var isDragged = false
    let drag: Drag

    var body: some View {
        let s = store.state(agent.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(status: s.status, size: 7)
                Text(agent.title).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
                Text(s.activity)
                    .font(.caption)
                    .foregroundStyle(s.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .shownInTiles(from: 460)
                Spacer(minLength: 6)
                TokenBadge(agents: [agent.id]).shownInTiles(from: 380)
                ChangesButton(agent: agent).shownInTiles(from: 280)
                Button { store.selection = .agent(agent.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open in its own tab")
                DeleteTileButton(title: "Delete this agent?",
                                 message: agent.branch != nil
                                     ? "Its session stops. Its branch \(agent.branch!) and any commits on it are kept."
                                     : "Its session stops. Files in the project are not touched.",
                                 confirm: "Delete Agent") {
                    Task { await store.deleteAgent(agent) }
                }
            }
            .contextMenu { AgentMenu(agent: agent) }
            .tileHeader(drag)

            AskBar(agentID: agent.id)
                .padding(.horizontal, 8)
                .padding(.bottom, s.ask != nil && s.status == .needsYou ? 6 : 0)

            Group {
                if s.status == .asleep || store.stopped.contains(agent.id) {
                    VStack(spacing: 10) {
                        Text(s.activity.isEmpty ? "Not running" : s.activity)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Start") { store.start(agent.id) }
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TerminalHost(agent: agent, focus: false)
                        .id(store.terminalGeneration[agent.id, default: 0])
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .tileChrome(isDragged: isDragged, highlight: s.status == .needsYou)
    }
}

/// A browser tab on the Canvas: its live page, which you can click and scroll in place.
struct BrowserTile<Drag: Gesture>: View {
    @Environment(AppStore.self) private var store
    let tab: BrowserTab
    var isDragged = false
    let drag: Drag

    var body: some View {
        let page = Browsers.page(for: tab, store: store)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                Text(page.title.isEmpty ? (URL(string: page.url)?.host() ?? "New tab") : page.title)
                    .font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
                Text(URL(string: page.url)?.host() ?? "")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    .shownInTiles(from: 360)
                Spacer(minLength: 6)
                Button {
                    if page.isLoading { page.webView.stopLoading() } else { page.webView.reload() }
                } label: {
                    Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(page.url.isEmpty)
                .help(page.isLoading ? "Stop loading" : "Reload")
                Button { store.selection = .browser(tab.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open in its own tab")
                DeleteTileButton(title: "Delete this browser tab?",
                                 message: "The page closes. You can open a new tab any time.",
                                 confirm: "Delete Tab") {
                    store.closeBrowserTab(tab.id)
                }
            }
            .tileHeader(drag)

            ZStack {
                WebViewHost(webView: page.webView)
                if page.url.isEmpty {
                    BrowserStartPage(project: store.project(tab.projectID)) { page.open($0) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .tileChrome(isDragged: isDragged, highlight: false)
        .contextMenu {
            Button("Close Tab") { store.closeBrowserTab(tab.id) }
        }
    }
}

/// The X in a tile's title bar. It asks in a small pop-up before deleting anything.
struct DeleteTileButton: View {
    let title: String
    let message: String
    let confirm: String
    /// Red, for things that are really deleted. Off for things that only leave the Canvas.
    var destructive = true
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        Button { asking = true } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .help(confirm)
            .popover(isPresented: $asking, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { asking = false }
                            .keyboardShortcut(.cancelAction)
                        Button(confirm, role: destructive ? .destructive : nil) {
                            asking = false
                            action()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .padding(14)
                .frame(width: 260)
            }
    }
}

extension View {
    /// A tile's title bar: the handle you drag it by.
    func tileHeader(_ drag: some Gesture) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(drag)
            // SwiftUI keeps this cursor up for as long as the pointer is over the bar. A pushed NSCursor
            // got reset by the terminal and buttons inside the tile, so the bar didn't look draggable.
            .pointerStyle(.grabIdle)
            .help("Drag to move")
    }

    /// The faint card every tile sits on, lifted while it's dragged. `highlight` gives it an orange edge.
    /// The tile takes the size it's given and is cut to the card, so nothing spills onto its neighbours.
    func tileChrome(isDragged: Bool, highlight: Bool) -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(isDragged ? Color.black.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(Theme.surface.opacity(isDragged ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlight ? Color.orange.opacity(0.6) : Theme.hairline.opacity(isDragged ? 2 : 1),
                              lineWidth: highlight ? 1 : 0.5))
            .shadow(color: .black.opacity(isDragged ? 0.55 : 0), radius: isDragged ? 24 : 0, y: isDragged ? 12 : 0)
            .scaleEffect(isDragged ? 1.03 : 1)
            .animation(Motion.bouncy, value: highlight)
    }
}
