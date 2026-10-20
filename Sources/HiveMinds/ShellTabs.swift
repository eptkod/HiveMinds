import SwiftUI
import AppKit
import SwiftTerm

/// One shell tab's live terminal. It lives as long as the tab, so switching tabs doesn't end the shell.
@MainActor @Observable
final class ShellSession {
    let id: UUID
    @ObservationIgnored let view: LocalProcessTerminalView
    /// The title the shell or the program in it sets, if any.
    var title = ""
    var running = false

    init(id: UUID, view: LocalProcessTerminalView) {
        self.id = id
        self.view = view
    }
}

/// The open shells, kept while their tabs exist. Each runs your login shell in its project's folder.
@MainActor
final class Shells: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = Shells()
    private var sessions: [UUID: ShellSession] = [:]

    func session(for tab: ShellTab, in folder: String) -> ShellSession {
        if let s = sessions[tab.id] { return s }
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        v.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        v.nativeBackgroundColor = Terminals.backgroundForSettings
        v.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        v.caretColor = .controlAccentColor
        v.processDelegate = self
        let s = ShellSession(id: tab.id, view: v)
        sessions[tab.id] = s
        start(s, in: folder)
        return s
    }

    /// The session if it's been opened this session, for tab titles.
    func existing(_ id: UUID) -> ShellSession? { sessions[id] }

    /// Starts the shell again after it exited, in the same terminal.
    func restart(_ id: UUID, in folder: String) {
        guard let s = sessions[id], !s.running else { return }
        s.view.feed(text: "\r\n")
        start(s, in: folder)
    }

    func close(_ id: UUID) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        s.view.processDelegate = nil
        if s.running { s.view.terminate() }
        s.view.removeFromSuperview()
    }

    func applyAppearance() {
        for s in sessions.values { s.view.nativeBackgroundColor = Terminals.backgroundForSettings }
    }

    private func start(_ s: ShellSession, in folder: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Shell.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let cwd = FileManager.default.fileExists(atPath: folder) ? folder : NSHomeDirectory()
        // A leading dash makes it a login shell, like Terminal opens, so your profile and PATH load.
        let name = "-" + (shell as NSString).lastPathComponent
        s.view.startProcess(executable: shell, args: [], environment: env.map { "\($0.key)=\($0.value)" },
                            execName: name, currentDirectory: cwd)
        s.running = true
    }

    private func session(of source: AnyObject) -> ShellSession? {
        sessions.values.first { $0.view === source }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.session(of: source)?.title = title }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let s = self.session(of: source) else { return }
            s.running = false
            source.feed(text: "\r\n\u{1b}[2m— Shell ended. Press Restart to open a new one. —\u{1b}[0m\r\n")
        }
    }
}

// MARK: Views

/// A shell tab opened on its own: the terminal fills the page.
struct ShellView: View {
    @Environment(AppStore.self) private var store
    let tab: ShellTab

    var body: some View {
        let folder = store.project(tab.projectID)?.path ?? NSHomeDirectory()
        let session = Shells.shared.session(for: tab, in: folder)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(session.title.isEmpty ? "Shell" : session.title)
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 6)
                if !session.running {
                    Button("Restart") { Shells.shared.restart(tab.id, in: folder) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ShellHost(session: session)
                .padding(10)
                .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .padding([.horizontal, .bottom], 14)
        }
    }
}

/// A shell tab on the Canvas: its live terminal, which you can type in place.
struct ShellTile<Drag: Gesture>: View {
    @Environment(AppStore.self) private var store
    let tab: ShellTab
    var isDragged = false
    let drag: Drag

    var body: some View {
        let folder = store.project(tab.projectID)?.path ?? NSHomeDirectory()
        let session = Shells.shared.session(for: tab, in: folder)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary)
                Text(session.title.isEmpty ? "Shell" : session.title)
                    .font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                if !session.running {
                    Button { Shells.shared.restart(tab.id, in: folder) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Restart the shell")
                }
                Button { store.selection = .shell(tab.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open in its own tab")
                DeleteTileButton(title: "Close this shell?",
                                 message: "The shell and anything still running in it stop. Files are not touched.",
                                 confirm: "Close Shell") {
                    store.closeShellTab(tab.id)
                }
            }
            .tileHeader(drag)

            ShellHost(session: session, focus: false)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .tileChrome(isDragged: isDragged, highlight: false)
    }
}

/// Puts a shell's long-lived terminal view into the SwiftUI layout.
struct ShellHost: NSViewRepresentable {
    let session: ShellSession
    /// Whether typing goes to this terminal as soon as it shows. Off for the tiles in a grid.
    var focus = true

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let term = session.view
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if focus { DispatchQueue.main.async { term.window?.makeFirstResponder(term) } }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
