import AppKit
import SwiftTerm
import HiveMindsCore
import HiveMindsProtocol

/// An agent's terminal on another machine, drawn here from the host's snapshot and output (docs/HOST-PROTOCOL.md §1).
/// Keystrokes and mouse go to the host; the terminal's own answers to the program don't, since only the host's
/// terminal may answer it. Those answers only ever happen while host output is being fed in, so anything the
/// terminal sends during a feed is dropped.
final class RemoteTerminalView: TerminalView, TerminalViewDelegate {
    var onInput: ([UInt8]) -> Void = { _ in }
    private var feeding = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func feedFromHost(_ bytes: [UInt8]) {
        feeding = true
        feed(byteArray: bytes[...])
        feeding = false
    }

    /// What the terminal itself sends: replies to the program's queries (dropped: they happen while feeding) and
    /// mouse reports from clicks and scrolls (passed on).
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !feeding else { return }
        onInput(Array(data))
    }

    // TerminalViewDelegate: keystrokes, paste and dictation arrive here.
    func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { copyToClipboard(s) }
    }
}

/// Holds a remote terminal at the agent's own size (its PTY on the host is sized to whoever is typing), shrinking
/// the font to fit when the space is smaller, and centring it when there's room to spare.
final class RemoteTerminalContainer: NSView {
    let agentID: UUID
    let term: RemoteTerminalView
    private(set) var cols = 120
    private(set) var rows = 40
    private(set) var sized = false
    private var waiting: [TerminalFrame] = []
    private var fittedFor: (NSSize, Int, Int)?
    static let baseFontSize: CGFloat = 12.5

    init(agentID: UUID) {
        self.agentID = agentID
        term = RemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        term.font = NSFont.monospacedSystemFont(ofSize: Self.baseFontSize, weight: .regular)
        term.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        term.caretColor = .controlAccentColor
        applyAppearance()
        addSubview(term)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyAppearance() {
        term.nativeBackgroundColor = Terminals.backgroundForSettings
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// The agent's terminal size (from `attach` or `resized`). Frames that came before it are fed now.
    func setSize(cols: Int, rows: Int) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 2)
        sized = true
        fittedFor = nil
        fit()
        let early = waiting
        waiting = []
        for f in early { take(f) }
    }

    func take(_ frame: TerminalFrame) {
        guard sized else { return waiting.append(frame) }
        term.feedFromHost(frame.bytes)
    }

    /// The space changed size (the tile or window was resized).
    var onSpaceChanged: () -> Void = {}

    private func fit() {
        guard bounds.width > 20, bounds.height > 20 else { return }
        if let f = fittedFor, f.0 == bounds.size, f.1 == cols, f.2 == rows { return }
        if fittedFor?.0 != bounds.size { onSpaceChanged() }
        fittedFor = (bounds.size, cols, rows)
        var size = Self.baseFontSize
        var frame = optimalFrame(fontSize: size)
        let scale = min(1, bounds.width / frame.width, bounds.height / frame.height)
        if scale < 1 {
            size = max(5, (Self.baseFontSize * scale * 2).rounded(.down) / 2)
            frame = optimalFrame(fontSize: size)
        }
        term.frame = NSRect(x: max(0, (bounds.width - frame.width) / 2), y: 0, width: frame.width, height: frame.height)
        // Setting the frame lets the view pick its own size from it; the agent's size is the one that counts.
        if let t = term.getTerminal() as Terminal?, t.cols != cols || t.rows != rows { t.resize(cols: cols, rows: rows) }
    }

    private func optimalFrame(fontSize: CGFloat) -> NSRect {
        if term.font.pointSize != fontSize { term.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        let t = term.getTerminal()
        if t.cols != cols || t.rows != rows { t.resize(cols: cols, rows: rows) }
        return term.getOptimalFrameSize()
    }

    /// The size this space would give at the normal font: what to ask for when this Mac takes control.
    func naturalSize() -> (cols: Int, rows: Int) {
        let probe = TerminalView(frame: bounds)
        probe.font = NSFont.monospacedSystemFont(ofSize: Self.baseFontSize, weight: .regular)
        probe.setFrameSize(bounds.size)
        let t = probe.getTerminal()
        return (max(t.cols, 20), max(t.rows, 5))
    }
}

/// The remote terminals that exist, one per agent on a host. They outlive the views showing them, like local ones,
/// so going back to an agent shows its screen at once.
@MainActor
final class RemoteTerminals {
    static let shared = RemoteTerminals()
    weak var store: AppStore?
    private var views: [UUID: RemoteTerminalContainer] = [:]
    private var resizeWork: [UUID: DispatchWorkItem] = [:]

    func existing(_ id: UUID) -> RemoteTerminalContainer? { views[id] }

    /// The agent's terminal, attaching to it on the host the first time.
    func view(for agent: Agent) -> RemoteTerminalContainer {
        if let v = views[agent.id] { return v }
        let v = RemoteTerminalContainer(agentID: agent.id)
        let id = agent.id
        v.term.onInput = { [weak self] bytes in self?.typed(id, bytes) }
        v.onSpaceChanged = { [weak self] in self?.viewResized(id) }
        views[agent.id] = v
        attach(id)
        return v
    }

    private func attach(_ id: UUID) {
        guard let host = store?.remoteHost(of: id) else { return }
        Task {
            guard let reply = try? await host.request(.attach(AgentRef(id))) else { return }
            views[id]?.setSize(cols: reply.cols ?? 120, rows: reply.rows ?? 40)
        }
    }

    /// The host is back: attach again (it sends a fresh snapshot).
    func reattach(hostID: String) {
        for id in views.keys where store?.remoteHost(of: id)?.id == hostID { attach(id) }
    }

    func received(_ f: TerminalFrame) {
        views[f.agentID]?.take(f)
    }

    func resized(_ id: UUID, cols: Int, rows: Int) {
        views[id]?.setSize(cols: cols, rows: rows)
    }

    func refused(_ id: UUID, controller: DeviceInfo) {
        store?.remoteInputRefused(id, controller: controller)
    }

    func detached(_ id: UUID) {
        views.removeValue(forKey: id)?.removeFromSuperview()
    }

    /// Forgets the agents of a host (forgotten or re-paired).
    func drop(hostAgents ids: [UUID]) {
        for id in ids { detached(id) }
    }

    func applyAppearance() { for v in views.values { v.applyAppearance() } }

    private func typed(_ id: UUID, _ bytes: [UInt8]) {
        store?.remoteHost(of: id)?.send(frame: TerminalFrame(.input, id, bytes))
    }

    /// This Mac takes control: the agent's terminal takes this view's size.
    func takeControl(_ id: UUID) async throws {
        guard let host = store?.remoteHost(of: id) else { return }
        let size = views[id]?.naturalSize() ?? (cols: 120, rows: 40)
        _ = try await host.request(.takeControl(SizedAgentRef(id, cols: size.cols, rows: size.rows)))
    }

    /// While this Mac is typing, its view's size is the agent's: say when it changes (after it settles).
    func viewResized(_ id: UUID) {
        guard let v = views[id], store?.isController(of: id) == true else { return }
        resizeWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let host = self.store?.remoteHost(of: id) else { return }
            let size = v.naturalSize()
            guard size.cols != v.cols || size.rows != v.rows else { return }
            Task { _ = try? await host.request(.resize(SizedAgentRef(id, cols: size.cols, rows: size.rows))) }
        }
        resizeWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
