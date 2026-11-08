import Foundation
import Testing
@testable import HiveMindsCore
#if canImport(Glibc)
import Glibc
#endif

/// Collects what a PTYProcess sends, and waits for things to show up.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var end: ProcessEnd?
    private let changed = DispatchSemaphore(value: 0)

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var ended: ProcessEnd? { lock.withLock { end } }

    func add(_ b: [UInt8]) { lock.withLock { bytes += b }; changed.signal() }
    func finish(_ e: ProcessEnd) { lock.withLock { end = e }; changed.signal() }

    /// Waits up to `seconds` for `ok`.
    @discardableResult
    func wait(_ seconds: Double = 10, until ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ok() {
            if Date() > deadline { return false }
            _ = changed.wait(timeout: .now() + 0.2)
        }
        return true
    }
}

func spawn(_ script: String, rows: Int = 30, cols: Int = 100, env: [String: String] = [:]) throws -> (PTYProcess, Collector) {
    let c = Collector()
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "C"]
    environment.merge(env) { $1 }
    let p = try PTYProcess(executable: "/bin/sh", arguments: ["-c", script], environment: environment, directory: "/",
                           rows: rows, cols: cols, queue: DispatchQueue(label: "pty-test"),
                           onOutput: { c.add($0) }, onExit: { c.finish($0) })
    return (p, c)
}

@Suite(.serialized) struct PTYProcessTests {
    @Test func reportsOutputAndTheExitCode() throws {
        let (p, c) = try spawn("printf 'hello from the pty'; exit 3")
        #expect(c.wait { c.ended != nil })
        #expect(c.text.contains("hello from the pty"))
        #expect(c.ended == .exited(3))
        #expect(p.pid > 0)
    }

    @Test func runsInItsOwnTerminalOfTheGivenSize() throws {
        let (_, c) = try spawn("stty size; tty; [ \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"$$\" ] && echo LEADER", rows: 33, cols: 101)
        #expect(c.wait { c.ended != nil })
        #expect(c.text.contains("33 101"))
        #expect(!c.text.contains("not a tty"))
        #expect(c.text.contains("/dev/"))
        #expect(c.text.contains("LEADER"))
    }

    @Test func passesOnNoOpenFilesOfOurs() throws {
        // An ordinary descriptor (not close-on-exec), as any library might leave open.
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        #expect(fd > 2)
        let (_, c) = try spawn("if [ -e /dev/fd/\(fd) ]; then echo LEAKED; else echo CLEAN; fi")
        #expect(c.wait { c.ended != nil })
        #expect(c.text.contains("CLEAN"))
    }

    @Test func signalsAreBackToTheirDefaults() throws {
        let old = signal(SIGUSR1, SIG_IGN)
        defer { signal(SIGUSR1, old) }
        // Ignored in the child, it would print "survived"; at its default, it ends the shell.
        let (_, c) = try spawn("kill -USR1 $$; echo survived")
        #expect(c.wait { c.ended != nil })
        #expect(c.ended == .signalled(SIGUSR1))
        #expect(!c.text.contains("survived"))
    }

    @Test func takesTypingAndResizes() throws {
        let (p, c) = try spawn("read line; echo \"got:$line\"; read again; stty size")
        p.write(Array("hi there\n".utf8))
        #expect(c.wait { c.text.contains("got:hi there") })
        p.resize(rows: 12, cols: 48)
        p.write(Array("\n".utf8))
        #expect(c.wait { c.ended != nil })
        #expect(c.text.contains("12 48"))
    }

    @Test func stopTakesTheWholeProcessGroup() throws {
        let (p, c) = try spawn("sleep 60 & echo \"child:$!\"; wait")
        #expect(c.wait { c.text.contains("child:") })
        let line = c.text.components(separatedBy: "child:").last ?? ""
        let child = pid_t(line.prefix { $0.isNumber }) ?? 0
        #expect(child > 0)
        p.terminate(grace: 2)
        #expect(c.wait { c.ended != nil })
        #expect(c.ended == .signalled(SIGTERM))
        // The background sleep went with it.
        var gone = false
        for _ in 0..<20 where !gone { gone = kill(child, 0) != 0; if !gone { usleep(100_000) } }
        #expect(gone)
    }

    @Test func aProgramThatIgnoresTermIsForced() throws {
        let (p, c) = try spawn("trap '' TERM; echo ready; while :; do sleep 1; done")
        #expect(c.wait { c.text.contains("ready") })
        p.terminate(grace: 0.5)
        #expect(c.wait(5) { c.ended != nil })
        #expect(c.ended == .signalled(SIGKILL))
    }

    @Test func aMissingProgramSaysSo() {
        do {
            _ = try PTYProcess(executable: "/nonexistent/claude", arguments: [], environment: [:], directory: "/",
                               rows: 24, cols: 80, queue: DispatchQueue(label: "x"), onOutput: { _ in }, onExit: { _ in })
            Issue.record("should have thrown")
        } catch let e as PTYProcess.LaunchError {
            #expect(e.errno == ENOENT)
            #expect(e.description.contains("/nonexistent/claude"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func aMissingFolderSaysSo() {
        #expect(throws: PTYProcess.LaunchError.self) {
            _ = try PTYProcess(executable: "/bin/sh", arguments: ["-c", "true"], environment: [:], directory: "/nonexistent-folder",
                               rows: 24, cols: 80, queue: DispatchQueue(label: "x"), onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func lotsOfOutputArrivesWhole() throws {
        let (_, c) = try spawn("i=0; while [ $i -lt 2000 ]; do echo \"line $i of output\"; i=$((i+1)); done; echo END")
        #expect(c.wait(20) { c.ended != nil })
        #expect(c.text.contains("line 1999 of output") && c.text.contains("END"))
    }
}

@Suite struct ShellTests {
    @Test func theLoginShellRunsWithNoTerminalAndCantHang() {
        // No controlling terminal, so an interactive shell can't try to take ours over and get stopped.
        #expect(Shell.runDetached("/bin/sh", ["-c", "tty"], timeout: 5).contains("not a tty"))
        let started = Date()
        _ = Shell.runDetached("/bin/sh", ["-c", "sleep 30"], timeout: 0.5)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(Shell.loginPath.split(separator: ":").contains("/usr/bin"))
    }
}
