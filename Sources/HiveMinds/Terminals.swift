import AppKit
import SwiftTerm
import HiveMindsCore
import HiveMindsProtocol

/// Keeps each agent's terminal (and the CLI process inside it) alive while you look at other things.
/// Agents start when you first open them, and resume their Claude Code session after a relaunch.
@MainActor
final class Terminals: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = Terminals()
    weak var store: AppStore?
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var tails: [UUID: EventTail] = [:]
    /// When each session was started, and whether it was resuming an earlier conversation.
    private var launches: [UUID: (at: Date, resumed: Bool)] = [:]

    static let background = NSColor.black

    /// The terminal background matches the window's, so it's see-through by the same amount.
    static var backgroundForSettings: NSColor {
        let stored = UserDefaults.standard.object(forKey: SettingKey.backgroundOpacity) as? Double
        let opacity = min(max(stored ?? SettingDefault.backgroundOpacity, 0.2), 1)
        return NSColor.black.withAlphaComponent(opacity)
    }

    func applyAppearance() {
        for view in views.values { view.nativeBackgroundColor = Terminals.backgroundForSettings }
    }

    func isRunning(_ id: UUID) -> Bool { views[id] != nil }

    func view(for agent: Agent) -> LocalProcessTerminalView {
        if let v = views[agent.id] { return v }
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        v.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        v.nativeBackgroundColor = Terminals.backgroundForSettings
        v.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        v.caretColor = .controlAccentColor
        v.processDelegate = self
        views[agent.id] = v
        start(agent, in: v)
        return v
    }

    private func start(_ agent: Agent, in v: LocalProcessTerminalView) {
        guard let store else { return }
        let executable = store.tools.path(for: agent.provider)
        if let problem = LaunchProblem.check(agent, executable: executable, machine: "this Mac") {
            v.feed(text: problem.note)
            store.setStatus(agent.id, .asleep, problem.activity)
            return
        }
        guard let exe = executable else { return }

        if agent.provider == .claude {
            let events = store.eventsFile(for: agent.id)
            FileManager.default.createFile(atPath: events.path, contents: Data())
            store.spend.watch(agent.id)
            let id = agent.id
            tails[id] = EventTail(url: events) { [weak self] json in
                self?.store?.apply(event: json, to: id)
            }
        }
        // The command line itself comes from HiveMindsCore, so HiveMinds Host starts agents the same way.
        let usesKey = SignIn.apiKey(for: .claude) != nil
        let plan = LaunchPlan.make(for: agent, LaunchContext(
            executable: exe, baseEnvironment: Shell.environment, signInEnvironment: SignIn.environment(for: agent.provider),
            codexSignInArgs: SignIn.codexArgs, claudeSettingsFile: (usesKey ? store.hooksWithKeyFile : store.hooksFile).path,
            eventsFile: store.eventsFile(for: agent.id).path, statusFile: store.statusFile(for: agent.id).path,
            defaultAccess: AgentDefaults.access, meetingSeatsAcceptEdits: MeetingDefaults.acceptEdits))
        if agent.provider == .claude { launches[agent.id] = (Date(), plan.resumes) }
        if plan.startsTaskNow { store.update(agent.id) { $0.pendingTask = nil; $0.hasStarted = true } }
        store.setStatus(agent.id, plan.status, plan.activity)

        v.startProcess(executable: plan.executable, args: plan.arguments, environment: plan.environment.map { "\($0.key)=\($0.value)" },
                       execName: nil, currentDirectory: plan.directory)
    }

    /// Types text into an agent's terminal and presses Return. It goes in as a paste, so Claude Code
    /// takes it as one message, and Return follows a moment later so it isn't part of the paste.
    func type(_ id: UUID, _ text: String) {
        guard let v = views[id] else { return }
        v.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak v] in v?.send(txt: "\r") }
    }

    /// Presses keys in an agent's terminal one after another, with a short gap so each prompt can redraw
    /// before the next key arrives. Used to answer a permission prompt or a question from a tile.
    func press(_ id: UUID, _ keys: [String]) {
        guard let v = views[id] else { return }
        for (i, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak v] in v?.send(txt: key) }
        }
    }

    /// The numbered choices of the menu on screen in an agent's terminal ("❯ 1. Yes, auto-accept edits").
    func menuOptions(_ id: UUID) -> [MenuOption] {
        guard let terminal = views[id]?.getTerminal() else { return [] }
        return PromptKeys.menuOptions(in: terminal)
    }

    #if DEBUG
    /// Sends keys as they are, for test runs.
    func sendKeys(_ id: UUID, _ keys: String) { views[id]?.send(txt: keys) }

    /// The visible screen as text, for test runs.
    func screenText(_ id: UUID) -> String? {
        guard let t = views[id]?.getTerminal() else { return nil }
        return TerminalSnapshot.screenText(t)
    }
    #endif

    func stop(_ id: UUID) {
        tails[id] = nil
        guard let v = views.removeValue(forKey: id) else { return }
        v.processDelegate = nil
        v.terminate()
        v.removeFromSuperview()
    }

    private func id(of source: AnyObject) -> UUID? {
        views.first { $0.value === source }?.key
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let id = self.id(of: source) else { return }
            self.tails[id] = nil
            self.views[id] = nil
            let launch = self.launches.removeValue(forKey: id)
            // The rule is HiveMindsCore's, shared with HiveMinds Host.
            let end = AgentExit.after(resumed: launch?.resumed ?? false, exitCode: exitCode,
                                      ranFor: launch.map { Date().timeIntervalSince($0.at) } ?? .infinity)
            if end.startsOver { self.store?.update(id) { $0.hasStarted = false; $0.sessionID = UUID() } }
            source.feed(text: end.note)
            self.store?.setStatus(id, .asleep, end.activity)
            if end.startsOver { Sounds.play(.error) }
        }
    }
}

/// Scrolling over a terminal whose program has taken the whole screen. Claude Code does this: it draws on
/// the alternate screen, which has no scrollback, and asks for mouse events so it can scroll its own chat.
/// SwiftTerm 1.11.2 only ever scrolls its scrollback, so a scroll did nothing there. This passes the scroll
/// on as mouse-wheel presses (or arrow keys, for a full-screen program that didn't ask for the mouse, like
/// `less`), one per line of travel. Scrolls over a plain shell go to SwiftTerm as before.
@MainActor
enum TerminalScroll {
    private static var travel: CGFloat = 0
    private static weak var last: TerminalView?

    /// Whether the scroll was passed to the program under the pointer, so nothing else should see it.
    static func take(_ event: NSEvent) -> Bool {
        guard let view = terminal(under: event), let term = view.terminal, term.isCurrentBufferAlternate else { return false }
        if view !== last || event.phase == .began || event.phase == .mayBegin {
            last = view
            travel = 0
        }
        let rows = max(term.rows, 1), cols = max(term.cols, 1)
        let rowHeight = view.bounds.height / CGFloat(rows)
        // A trackpad reports points, a mouse wheel reports lines.
        travel += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / max(rowHeight, 1) : event.scrollingDeltaY
        let steps = Int(travel.magnitude)
        guard steps > 0 else { return true }
        let up = travel > 0
        travel -= up ? CGFloat(steps) : -CGFloat(steps)

        if view.allowMouseReporting && term.mouseMode != .off {
            let p = view.convert(event.locationInWindow, from: nil)
            let col = min(max(Int(p.x / (view.bounds.width / CGFloat(cols))), 0), cols - 1)
            let row = min(max(Int((view.bounds.height - p.y) / max(rowHeight, 1)), 0), rows - 1)
            let flags = event.modifierFlags
            let button = term.encodeButton(button: up ? 4 : 5, release: false, shift: flags.contains(.shift),
                                           meta: flags.contains(.option), control: flags.contains(.control))
            for _ in 0..<min(steps, 20) { term.sendEvent(buttonFlags: button, x: col, y: row) }
        } else {
            let key = up
                ? (term.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                : (term.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0..<min(steps, 20) { view.send(key) }
        }
        return true
    }

    private static func terminal(under event: NSEvent) -> TerminalView? {
        guard let content = event.window?.contentView, let frame = content.superview else { return nil }
        var view = content.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let v = view {
            if let term = v as? TerminalView { return term }
            view = v.superview
        }
        return nil
    }
}
