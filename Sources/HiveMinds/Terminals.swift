import AppKit
import SwiftTerm

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
        guard let exe = store.tools.path(for: agent.provider) else {
            v.feed(text: "\(agent.provider.label) isn't installed on this Mac.\r\n")
            store.setStatus(agent.id, .asleep, "\(agent.provider.label) isn't installed")
            return
        }
        guard FileManager.default.fileExists(atPath: agent.cwd) else {
            v.feed(text: "This agent's folder is gone: \(agent.cwd)\r\n")
            store.setStatus(agent.id, .asleep, "Its folder is missing")
            return
        }

        var env = Shell.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["HIVEMINDS_AGENT"] = agent.id.uuidString
        env.merge(SignIn.environment(for: agent.provider)) { $1 }

        var args: [String] = []
        switch agent.provider {
        case .claude:
            let events = store.eventsFile(for: agent.id)
            FileManager.default.createFile(atPath: events.path, contents: Data())
            env["HIVEMINDS_EVENTS"] = events.path
            env["HIVEMINDS_STATUS"] = store.statusFile(for: agent.id).path
            store.spend.watch(agent.id)
            let id = agent.id
            tails[id] = EventTail(url: events) { [weak self] json in
                self?.store?.apply(event: json, to: id)
            }
            let session = agent.sessionID.uuidString.lowercased()
            args += agent.hasStarted ? ["--resume", session] : ["--session-id", session]
            launches[agent.id] = (Date(), agent.hasStarted)
            let usesKey = SignIn.apiKey(for: .claude) != nil
            args += ["--settings", (usesKey ? store.hooksWithKeyFile : store.hooksFile).path]
            if agent.model != "default" { args += ["--model", agent.model] }
            args += agent.provider.effortArgs(agent.effort)
            if !agent.role.isEmpty { args += ["--append-system-prompt", agent.role] }
            // Meeting seats use the default access from Settings > Agents, unless they were given their own.
            let access = agent.access ?? (agent.meetingID != nil ? AgentDefaults.access : nil)
            if let access { args += access.args(for: .claude) }
            // On Manual review, meeting seats still write their notes without stopping to ask, unless you turned that off.
            if agent.meetingID != nil && access == .manual && MeetingDefaults.acceptEdits { args += ["--permission-mode", "acceptEdits"] }
            if !agent.hasStarted, let task = agent.pendingTask { args.append(task) }
            store.setStatus(agent.id, .starting, "Starting up")
        case .codex:
            args += SignIn.codexArgs
            if agent.model != "default" { args += ["--model", agent.model] }
            args += agent.provider.effortArgs(agent.effort)
            if let access = agent.access { args += access.args(for: .codex) }
            if let task = agent.pendingTask {
                args.append(task)
                store.update(agent.id) { $0.pendingTask = nil; $0.hasStarted = true }
            }
            store.setStatus(agent.id, .idle, "Running in its terminal")
        }

        v.startProcess(executable: exe, args: args, environment: env.map { "\($0.key)=\($0.value)" },
                       execName: nil, currentDirectory: agent.cwd)
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

    #if DEBUG
    /// Sends keys as they are, for test runs.
    func sendKeys(_ id: UUID, _ keys: String) { views[id]?.send(txt: keys) }
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
            if let launch, launch.resumed, exitCode != 0, Date().timeIntervalSince(launch.at) < 8 {
                // The earlier conversation couldn't be reopened (for example it was deleted). Start a new one next time.
                self.store?.update(id) { $0.hasStarted = false; $0.sessionID = UUID() }
                source.feed(text: "\r\n\u{1b}[2m— The earlier conversation couldn't be reopened. Press Restart to begin a new one. —\u{1b}[0m\r\n")
                self.store?.setStatus(id, .asleep, "Couldn't reopen its conversation")
                Sounds.play(.error)
                return
            }
            source.feed(text: "\r\n\u{1b}[2m— Session ended. Press Restart to pick up where it left off. —\u{1b}[0m\r\n")
            self.store?.setStatus(id, .asleep, "Session ended")
        }
    }
}

/// Follows a file that grows a line at a time, using a kernel file watch rather than polling.
final class EventTail {
    private let source: DispatchSourceFileSystemObject
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var buffer = Data()
    private let onEvent: ([String: Any]) -> Void

    init?(url: URL, onEvent: @escaping ([String: Any]) -> Void) {
        let fd = open(url.path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.onEvent = onEvent
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        offset = handle.seekToEndOfFile()
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in self?.readNew() }
        source.resume()
    }

    deinit { source.cancel() }

    private func readNew() {
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onEvent(obj)
            }
        }
    }
}
