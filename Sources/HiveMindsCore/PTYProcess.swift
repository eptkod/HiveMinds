import Foundation
import CHiveMindsSystem
#if canImport(Glibc)
import Glibc
#endif

/// How a program ended.
package enum ProcessEnd: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)

    /// The exit code, or nil when a signal ended it.
    package var code: Int32? {
        if case .exited(let c) = self { return c }
        return nil
    }

    init(waitStatus s: Int32) {
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift doesn't import as functions.
        if s & 0x7f == 0 { self = .exited((s >> 8) & 0xff) } else { self = .signalled(s & 0x7f) }
    }
}

/// A program running in its own pseudo-terminal, for HiveMinds Host (the app's This Mac agents still run in
/// SwiftTerm's terminal views). Unlike SwiftTerm's `LocalProcess`, it reports the exit on Linux too (a pidfd),
/// reaps the process, passes no open files of ours to the program, and stops the whole process group.
///
/// Everything happens on `queue`: output and the exit are delivered there, and the other methods may be called
/// from anywhere.
package final class PTYProcess: @unchecked Sendable {
    package struct LaunchError: Error, CustomStringConvertible {
        package var errno: Int32
        package var executable: String
        package var description: String { "Couldn't start \(executable): \(String(cString: strerror(errno)))" }
    }

    package let pid: pid_t
    private let master: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var exitWatch: DispatchSourceProtocol?
    private var writer: DispatchSourceWrite?
    private var unsent: [UInt8] = []
    private var ended: ProcessEnd?
    private var closed = false
    private var onOutput: (([UInt8]) -> Void)?
    private var onExit: ((ProcessEnd) -> Void)?
    /// A running program keeps this object alive until it has ended and been reaped, so dropping the last
    /// reference can never leave a child nobody watches.
    private var keepAlive: PTYProcess?

    /// Starts the program. `onOutput` gets what it writes to the terminal; `onExit` is called once, after the
    /// last output, when it has ended. Both run on `queue`.
    package init(executable: String, arguments: [String], environment: [String: String], directory: String?,
                 rows: Int, cols: Int, queue: DispatchQueue,
                 onOutput: @escaping ([UInt8]) -> Void, onExit: @escaping (ProcessEnd) -> Void) throws {
        self.queue = queue
        self.onOutput = onOutput
        self.onExit = onExit
        var masterFD: Int32 = -1
        var child: pid_t = 0
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        let err = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                hiveminds_spawn_pty(executable, a.baseAddress, e.baseAddress, directory,
                                    UInt16(clamping: rows), UInt16(clamping: cols), &masterFD, &child)
            }
        }
        guard err == 0 else { throw LaunchError(errno: err, executable: executable) }
        master = masterFD
        pid = child
        keepAlive = self
        queue.async { self.watch() }
    }

    deinit {
        if !closed { close(master) }
    }

    private func watch() {
        let r = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        r.setEventHandler { [weak self] in self?.drain() }
        reader = r
        r.resume()
        #if os(macOS)
        let w = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        w.setEventHandler { [weak self] in self?.reap() }
        exitWatch = w
        w.resume()
        #else
        let fd = hiveminds_pidfd_open(pid)
        if fd >= 0 {
            let w = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            w.setEventHandler { [weak self] in self?.reap() }
            w.setCancelHandler { close(fd) }
            exitWatch = w
            w.resume()
        } else {
            // Kernels before 5.3 have no pidfd: notice the end when the terminal closes instead.
            exitWatch = nil
        }
        #endif
        // It may have ended before the watch was set up.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { finish(ProcessEnd(waitStatus: status)) }
    }

    /// Reads everything the program has written so far. Returns false at the end of its output.
    @discardableResult
    private func drain() -> Bool {
        guard !closed else { return false }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if n > 0 {
                onOutput?(Array(buffer[0..<n]))
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
            if n < 0 && errno == EINTR { continue }
            // 0 or EIO: every program holding the terminal has closed it.
            reader?.cancel()
            reader = nil
            if exitWatch == nil {
                var status: Int32 = 0
                if waitpid(pid, &status, 0) == pid { finish(ProcessEnd(waitStatus: status)) }
            }
            return false
        }
    }

    private func reap() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else { return }
        finish(ProcessEnd(waitStatus: status))
    }

    private func finish(_ end: ProcessEnd) {
        guard ended == nil else { return }
        ended = end
        drain()
        exitWatch?.cancel()
        exitWatch = nil
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        if !closed { closed = true; close(master) }
        // Anything it left behind in its process group goes too.
        kill(-pid, SIGHUP)
        let done = onExit
        onOutput = nil
        onExit = nil
        done?(end)
        keepAlive = nil
    }

    /// Whether it has ended. Read on `queue`.
    package var hasEnded: Bool { ended != nil }

    /// Sends bytes to the program, as if typed.
    package func write(_ bytes: [UInt8]) {
        queue.async {
            guard self.ended == nil, !self.closed else { return }
            self.unsent += bytes
            self.flush()
        }
    }

    private func flush() {
        while !unsent.isEmpty {
            let n = unsent.withUnsafeBytes { systemWrite(master, $0.baseAddress, $0.count) }
            if n > 0 { unsent.removeFirst(n); continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // The terminal is full: carry on once it can take more.
                if writer == nil {
                    let w = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    w.setEventHandler { [weak self] in self?.flush() }
                    writer = w
                    w.resume()
                }
                return
            }
            unsent.removeAll()
            break
        }
        writer?.cancel()
        writer = nil
    }

    /// Changes the terminal's size; the program gets SIGWINCH.
    package func resize(rows: Int, cols: Int) {
        queue.async {
            guard !self.closed else { return }
            _ = hiveminds_pty_resize(self.master, UInt16(clamping: rows), UInt16(clamping: cols))
        }
    }

    /// Asks the program and its process group to stop (SIGTERM), then forces it (SIGKILL) after `grace` seconds.
    package func terminate(grace: TimeInterval = 3) {
        queue.async { [self] in
            guard self.ended == nil else { return }
            kill(-self.pid, SIGTERM)
            kill(self.pid, SIGTERM)
            let pid = self.pid
            self.queue.asyncAfter(deadline: .now() + grace) { [weak self] in
                guard let self, self.ended == nil else { return }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    /// Stops it now (SIGKILL to the process group).
    package func forceStop() {
        queue.async {
            guard self.ended == nil else { return }
            kill(-self.pid, SIGKILL)
            kill(self.pid, SIGKILL)
        }
    }
}

/// `write(2)`; a name of its own because `PTYProcess.write(_:)` hides the C function inside the class.
@inline(__always)
private func systemWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buf, count)
}
