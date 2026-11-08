import Foundation
import SwiftTerm

/// Throws terminal replies away. Used for viewers' terminals: only the host's terminal may answer the program,
/// otherwise every viewer would answer each query again.
final class SilentDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// An agent on the host: a process in a PTY plus a headless terminal that mirrors its screen.
/// Everything (feeding, snapshots, viewers) happens on `queue`, so a snapshot and the stream after it never interleave.
final class PtyAgent: TerminalDelegate, LocalProcessDelegate {
    let queue = DispatchQueue(label: "agent")
    private(set) var terminal: Terminal!
    private(set) var process: LocalProcess!
    var onOutput: ([UInt8]) -> Void = { _ in }
    var onExit: (Int32?) -> Void = { _ in }
    private(set) var bytesSeen = 0

    init(cols: Int, rows: Int) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000))
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    func start(_ exe: String, _ args: [String], cwd: String) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        queue.sync {
            process.startProcess(executable: exe, args: args, environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: cwd)
        }
    }

    func stop() { queue.sync { process.terminate() } }

    // LocalProcessDelegate (called on `queue`)
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { onExit(exitCode) }
    func dataReceived(slice: ArraySlice<UInt8>) {
        bytesSeen += slice.count
        terminal.feed(buffer: slice)
        onOutput(Array(slice))
    }
    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    // TerminalDelegate: the headless terminal answers the program's queries (cursor position, device attributes).
    func send(source: Terminal, data: ArraySlice<UInt8>) { process.send(data: data) }
}
