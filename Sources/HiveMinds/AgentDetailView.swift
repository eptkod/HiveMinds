import SwiftUI
import AppKit
import SwiftTerm

struct AgentDetailView: View {
    @Environment(AppStore.self) private var store
    let agent: Agent
    @State private var showingPR = false

    var body: some View {
        let s = store.state(agent.id)
        let isStopped = store.stopped.contains(agent.id)
        VStack(spacing: 0) {
            // One quiet line: who, what it's doing, and the few things you can do to it.
            HStack(spacing: 10) {
                StatusDot(status: s.status, size: 7)
                Text(agent.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(s.activity.isEmpty ? s.status.label : s.activity)
                    .font(.callout)
                    .foregroundStyle(s.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(shortDetails)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(details)
                TokenBadge(agents: [agent.id])
                HStack(spacing: 2) {
                    ChangesButton(agent: agent)
                    if agent.branch != nil {
                        Button { showingPR = true } label: {
                            if let pr = agent.pullRequest {
                                Label("#\(pr.number) \(pr.label)", systemImage: "arrow.triangle.pull").labelStyle(.titleAndIcon)
                                    .font(.caption)
                            } else {
                                Image(systemName: "arrow.triangle.pull")
                            }
                        }
                        .help(agent.pullRequest == nil ? "Open a pull request for its branch" : "Its pull request")
                    }
                    Menu {
                        Button("Show Changes…") { store.showingChanges = agent }
                            .disabled(!store.canShowChanges(agent))
                        Divider()
                        Button("Show in Finder") { store.revealInFinder(agent.cwd) }
                        OpenInMenu(path: agent.cwd)
                        Button("Copy Folder Path") { copyToClipboard(agent.cwd) }
                        if let branch = agent.branch {
                            Button("Copy Branch Name") { copyToClipboard(branch) }
                        }
                        Divider()
                        Menu("Restart With") { AgentMenu.RestartWith(agent: agent) }
                            .disabled(!store.canRestartWith(agent))
                    } label: { Image(systemName: "folder") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Its changes and folder: open it in Finder or an editor, or copy its path or branch")
                    Button { store.restart(agent.id) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Restart. Claude Code picks up the same conversation.")
                    if isStopped || s.status == .asleep {
                        Button { store.start(agent.id) } label: { Image(systemName: "play.fill") }
                            .help("Start")
                    } else {
                        Button { store.stop(agent.id) } label: { Image(systemName: "stop.fill") }
                            .help("Stop. Press Start to resume the same conversation.")
                    }
                }
                .buttonStyle(.borderless)
                .imageScale(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
                .animation(Motion.bouncy, value: isStopped || s.status == .asleep)
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .padding(.vertical, 6)

            Group {
                if isStopped {
                    VStack(spacing: 10) {
                        Text("Stopped").foregroundStyle(.secondary)
                        Button("Start") { store.start(agent.id) }
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TerminalHost(agent: agent)
                        .id(store.terminalGeneration[agent.id, default: 0])
                        .padding(10)
                }
            }
            .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding([.horizontal, .bottom], 14)
        }
        .sheet(isPresented: $showingPR) { PullRequestSheet(agent: agent) }
        .task(id: agent.id) { await store.refreshPullRequest(agent.id) }
    }

    /// Model and branch (or project). The full details, path included, are in the tooltip.
    private var shortDetails: String {
        var parts: [String] = []
        if agent.model != "default" { parts.append(agent.model) }
        parts.append(agent.branch ?? (store.project(agent.projectID)?.name ?? ""))
        return parts.joined(separator: " · ")
    }

    private var details: String {
        var parts = [agent.provider.label]
        if agent.model != "default" { parts.append(agent.model) }
        if let e = agent.effort { parts.append("\(e.label.lowercased()) effort") }
        parts.append(agent.branch.map { "branch \($0)" } ?? (store.project(agent.projectID)?.name ?? ""))
        parts.append(agent.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        return parts.joined(separator: " · ")
    }
}

/// Puts the agent's long-lived terminal view into the SwiftUI layout.
struct TerminalHost: NSViewRepresentable {
    let agent: Agent
    /// Whether typing goes to this terminal as soon as it shows. Off for the tiles in a grid.
    var focus = true

    func makeNSView(context: Context) -> NSView {
        TerminalSlot(term: Terminals.shared.view(for: agent), focus: focus)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Holds a long-lived terminal view in the layout. A terminal can only be in one place, but for a moment two
/// slots can want it: opening a new agent adds its tile to the Canvas while the Canvas is still fading out,
/// and that tile took the terminal from the agent's own tab, leaving the tab blank. So when a slot goes away
/// it hands the terminal back to the newest slot still on screen.
final class TerminalSlot: NSView {
    private static var live: [ObjectIdentifier: [TerminalSlot]] = [:]
    private let term: NSView
    private let focus: Bool

    init(term: NSView, focus: Bool) {
        self.term = term
        self.focus = focus
        super.init(frame: .zero)
        adopt()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var key: ObjectIdentifier { ObjectIdentifier(term) }

    private func adopt() {
        guard term.superview !== self else { return }
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: leadingAnchor),
            term.trailingAnchor.constraint(equalTo: trailingAnchor),
            term.topAnchor.constraint(equalTo: topAnchor),
            term.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        var slots = Self.live[key, default: []].filter { $0 !== self }
        if window != nil {
            slots.append(self)
            adopt()
            if focus { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.term) } }
        } else if term.superview === self || term.superview == nil {
            slots.last?.adopt()
        }
        Self.live[key] = slots.isEmpty ? nil : slots
    }
}
