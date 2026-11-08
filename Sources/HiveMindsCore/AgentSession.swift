import Foundation
import SwiftTerm

/// One agent's CLI running on HiveMinds Host: its process in a pseudo-terminal, a headless terminal that keeps
/// its screen, its hook events, and its live status. The rules are the same ones the app uses for This Mac
/// (`LaunchPlan`, `HookInterpreter`, `PromptResponder`, `AgentExit`), so an agent behaves the same wherever it runs.
///
/// Everything happens on `queue`. Observers are called there, in order; the methods may be called from anywhere.
package final class AgentSession: @unchecked Sendable {
    package enum Event: Sendable {
        /// Its status, activity or question changed.
        case state(LiveState)
        /// Its saved record changed (title, started, session id): save it.
        case agent(Agent)
        /// Bytes it drew in its terminal.
        case output([UInt8])
        /// It started a chat with this request and has no title yet: a better one can be asked for.
        case wantsTitle(String)
        /// A turn ended.
        case turnEnded
        /// Its CLI has ended.
        case exited
        /// Its terminal changed size; the snapshot rebuilds the reflowed screen at the new size.
        case resized(cols: Int, rows: Int, snapshot: [UInt8])
    }

    package let queue: DispatchQueue
    private var agentValue: Agent
    private var stateValue = LiveState()
    package let terminal: Terminal
    private let replies = Replies()
    private var process: PTYProcess?
    private var tail: EventTail?
    private var launch: (at: Date, resumed: Bool)?
    private var stopping = false
    private var pendingInput: String?
    private var observers: [UUID: (Event) -> Void] = [:]
    private var exitWaiters: [() -> Void] = []
    private var transcriptPaths: [String] = []

    package init(agent: Agent, cols: Int = 120, rows: Int = 40, scrollback: Int = 10_000, queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(label: "hiveminds.agent.\(agent.id.uuidString.prefix(8))")
        agentValue = agent
        terminal = Terminal(delegate: replies, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        replies.session = self
    }

    // MARK: Reading
    // These wait for `queue`, so they mustn't be called on it (an observer already gets what changed).

    package var agent: Agent { read { agentValue } }
    package var state: LiveState { read { stateValue } }
    package var isRunning: Bool { read { process != nil } }

    /// The bytes that rebuild its screen and scrollback in a fresh terminal of the same size.
    package func snapshot() -> [UInt8] { read { TerminalSnapshot.make(terminal) } }
    package func screenText() -> String { read { TerminalSnapshot.screenText(terminal) } }
    package func menuOptions() -> [MenuOption] { read { PromptKeys.menuOptions(in: terminal) } }
    /// Its terminal's size.
    package var size: (cols: Int, rows: Int) { read { (terminal.cols, terminal.rows) } }
    /// The Claude Code transcripts its hook events named (for `Git.changes`).
    package var transcripts: [String] { read { transcriptPaths } }

    private func read<T>(_ body: () -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync(execute: body)
    }

    /// Calls `handler` on `queue` for everything that happens from now on. Returns a token for `stopObserving`.
    @discardableResult
    package func observe(_ handler: @escaping (Event) -> Void) -> UUID {
        let token = UUID()
        read { observers[token] = handler }
        return token
    }

    package func stopObserving(_ token: UUID) { queue.async { self.observers[token] = nil } }

    /// For a viewer: calls `snapshot` with the bytes that rebuild the screen now (and the size), then `handler` for
    /// everything after, with nothing in between. Both run on `queue`. Returns a token for `stopObserving`.
    @discardableResult
    package func attach(snapshot: @escaping ([UInt8], Int, Int) -> Void, _ handler: @escaping (Event) -> Void) -> UUID {
        let token = UUID()
        read {
            snapshot(TerminalSnapshot.make(terminal), terminal.cols, terminal.rows)
            observers[token] = handler
        }
        return token
    }

    private func emit(_ event: Event) {
        for o in observers.values { o(event) }
    }

    // MARK: Starting and stopping

    /// Starts the CLI. `executable` is nil when the provider isn't installed. `eventsFile` is where its hooks append
    /// events (`context.eventsFile` as a URL). Text in `typeOnStart` is typed once its session is up.
    package func start(executable: String?, context: @escaping (String) -> LaunchContext, machine: String = "this host", typeOnStart: String? = nil) {
        queue.async { self.startNow(executable: executable, context: context, machine: machine, typeOnStart: typeOnStart) }
    }

    private func startNow(executable: String?, context: (String) -> LaunchContext, machine: String, typeOnStart: String?) {
        guard process == nil else { return }
        stopping = false
        if let problem = LaunchProblem.check(agentValue, executable: executable, machine: machine) {
            show(problem.note)
            setState(.asleep, problem.activity)
            return
        }
        guard let exe = executable else { return }
        let c = context(exe)
        pendingInput = typeOnStart
        if agentValue.provider == .claude {
            let events = URL(fileURLWithPath: c.eventsFile)
            _ = FileManager.default.createFile(atPath: events.path, contents: Data())
            tail = EventTail(url: events, queue: queue) { [weak self] json in self?.apply(event: json) }
        }
        let plan = LaunchPlan.make(for: agentValue, c)
        launch = agentValue.provider == .claude ? (Date(), plan.resumes) : nil
        if plan.startsTaskNow {
            agentValue.pendingTask = nil
            agentValue.hasStarted = true
            emit(.agent(agentValue))
        }
        setState(plan.status, plan.activity)
        do {
            process = try PTYProcess(executable: plan.executable, arguments: plan.arguments, environment: plan.environment,
                                     directory: plan.directory, rows: terminal.rows, cols: terminal.cols, queue: queue,
                                     onOutput: { [weak self] bytes in self?.received(bytes) },
                                     onExit: { [weak self] end in self?.ended(end) })
        } catch {
            tail = nil
            launch = nil
            show("\(error)\r\n")
            setState(.asleep, "Couldn't start")
        }
    }

    /// Stops it (SIGTERM, then SIGKILL after `grace` seconds). Its status reads "Stopped"; nothing is lost, and
    /// starting it again picks up the conversation.
    package func stop(grace: TimeInterval = 3) {
        queue.async {
            guard let process = self.process else { return }
            self.stopping = true
            self.pendingInput = nil
            process.terminate(grace: grace)
        }
    }

    /// Stops it straight away (SIGKILL).
    package func forceStop() {
        queue.async {
            guard let process = self.process else { return }
            self.stopping = true
            process.forceStop()
        }
    }

    /// Calls `done` on `queue` once its CLI isn't running (straight away if it isn't).
    package func whenStopped(_ done: @escaping () -> Void) {
        queue.async {
            if self.process == nil { done() } else { self.exitWaiters.append(done) }
        }
    }

    private func received(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
        emit(.output(bytes))
    }

    private func ended(_ end: ProcessEnd) {
        process = nil
        tail = nil
        let wasStopping = stopping
        stopping = false
        let launch = self.launch
        self.launch = nil
        if wasStopping {
            setState(.asleep, "Stopped")
        } else {
            let exit = AgentExit.after(resumed: launch?.resumed ?? false, exitCode: end.code,
                                       ranFor: launch.map { Date().timeIntervalSince($0.at) } ?? .infinity)
            if exit.startsOver {
                agentValue.hasStarted = false
                agentValue.sessionID = UUID()
                emit(.agent(agentValue))
            }
            show(exit.note)
            setState(.asleep, exit.activity)
        }
        emit(.exited)
        let waiters = exitWaiters
        exitWaiters = []
        for w in waiters { w() }
    }

    /// Writes a line of our own into its terminal, as viewers will see it.
    private func show(_ text: String) {
        let bytes = Array(text.utf8)
        terminal.feed(byteArray: bytes)
        emit(.output(bytes))
    }

    private func setState(_ status: AgentStatus, _ activity: String?) {
        stateValue.set(status, activity)
        emit(.state(stateValue))
    }

    // MARK: Hook events

    private func apply(event: [String: Any]) {
        if let path = event["transcript_path"] as? String, !path.isEmpty, !transcriptPaths.contains(path) {
            transcriptPaths.append(path)
        }
        let now = HookAgentState(status: stateValue.status, activity: stateValue.activity, ask: stateValue.ask?.kind,
                                 hasStarted: agentValue.hasStarted, isUntitled: agentValue.isUntitled)
        for effect in HookInterpreter.effects(of: event, state: now) {
            switch effect {
            case .status(let status, let activity, _):
                setState(status, activity)
            case .ask(let kind):
                stateValue.ask = PendingAsk(kind: kind)
                emit(.state(stateValue))
            case .typePendingInput:
                if let text = pendingInput {
                    pendingInput = nil
                    // Give Claude Code a moment to draw its prompt before typing into it.
                    queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.typeNow(text) }
                }
            case .markStarted:
                agentValue.hasStarted = true
                agentValue.pendingTask = nil
                emit(.agent(agentValue))
            case .retitle(let prompt):
                agentValue.title = Agent.roughTitle(prompt)
                emit(.agent(agentValue))
                emit(.wantsTitle(prompt))
            case .turnEnded:
                emit(.turnEnded)
            }
        }
    }

    /// Sets a better title (from `ChatTitle`).
    package func setTitle(_ title: String) {
        queue.async {
            self.agentValue.title = title
            self.emit(.agent(self.agentValue))
        }
    }

    // MARK: Typing and answering

    /// Bytes as they are, as if typed into its terminal.
    package func input(_ bytes: [UInt8]) {
        queue.async { self.process?.write(bytes) }
    }

    /// Types text and presses Return. It goes in as a paste, so Claude Code takes it as one message, and Return
    /// follows a moment later so it isn't part of the paste.
    package func type(_ text: String) {
        queue.async { self.typeNow(text) }
    }

    private func typeNow(_ text: String) {
        process?.write(Array(("\u{1b}[200~" + text + "\u{1b}[201~").utf8))
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.process?.write([13]) }
    }

    /// Presses keys one after another, with a short gap so each prompt can redraw before the next key arrives.
    package func press(_ keys: [String]) {
        queue.async { self.pressNow(keys) }
    }

    private func pressNow(_ keys: [String]) {
        for (i, key) in keys.enumerated() {
            queue.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in self?.process?.write(Array(key.utf8)) }
        }
    }

    /// Answers what it's asking, as a tile would. Returns what happened (on `queue`, through `done`).
    package func respond(_ action: PromptAction, done: @escaping (PromptResponse) -> Void = { _ in }) {
        queue.async {
            let response = PromptResponder.respond(action, ask: self.stateValue.ask?.kind, access: self.agentValue.access,
                                                   menu: { PromptKeys.menuOptions(in: self.terminal) })
            if case .press(let keys, let status, let activity) = response {
                self.pressNow(keys)
                self.setState(status, activity)
            }
            done(response)
        }
    }

    /// Changes the terminal's size, for the person typing.
    package func resize(cols: Int, rows: Int) {
        queue.async {
            guard cols > 1, rows > 1, cols != self.terminal.cols || rows != self.terminal.rows else { return }
            self.terminal.resize(cols: cols, rows: rows)
            self.process?.resize(rows: rows, cols: cols)
            self.emit(.resized(cols: cols, rows: rows, snapshot: TerminalSnapshot.make(self.terminal)))
        }
    }

    /// The headless terminal answers the program's questions (cursor position, device attributes) itself.
    private final class Replies: TerminalDelegate {
        weak var session: AgentSession?
        func send(source: Terminal, data: ArraySlice<UInt8>) { session?.process?.write(Array(data)) }
    }
}
