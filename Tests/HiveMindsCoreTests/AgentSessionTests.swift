import Foundation
import Testing
@testable import HiveMindsCore
import SwiftTerm

/// A stand-in for Claude Code: prints its arguments, then writes hook events to $HIVEMINDS_EVENTS the way Claude
/// Code's hooks do, reacting to what's typed into it.
let fakeClaude = #"""
#!/bin/sh
ev() { printf '%s\n' "$1" >> "$HIVEMINDS_EVENTS"; }
echo "FAKE ARGS: $*"
case " $* " in *" --resume "*) [ -n "$FAKE_RESUME_FAILS" ] && { echo "No conversation found"; exit 1; } ;; esac
ev '{"hook_event_name":"SessionStart"}'
IFS= read -r line
prompt=$(printf '%s' "$line" | tr -d '\033' | sed 's/\[200~//; s/\[201~//')
echo "PROMPT: $prompt"
ev "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$prompt\"}"
ev '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","description":"listing files"}}'
ev '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
printf '  ❯ 1. Yes\n    2. No, and tell Claude what to do differently\n'
stty -icanon -echo min 1
key=$(dd bs=1 count=1 2>/dev/null)
stty icanon echo
echo "KEY: $key"
ev '{"hook_event_name":"Stop"}'
IFS= read -r rest
"""#

/// Follows a session's events and waits for states.
final class SessionWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [LiveState] = []
    private var agents: [Agent] = []
    private var titles: [String] = []
    private var exits = 0
    private let changed = DispatchSemaphore(value: 0)

    init(_ s: AgentSession) {
        s.observe { [self] e in
            lock.withLock {
                switch e {
                case .state(let st): states.append(st)
                case .agent(let a): agents.append(a)
                case .wantsTitle(let t): titles.append(t)
                case .exited: exits += 1
                default: break
                }
            }
            changed.signal()
        }
    }

    var activities: [String] { lock.withLock { states.map { "\($0.status.rawValue): \($0.activity)" } } }
    var lastState: LiveState? { lock.withLock { states.last } }
    var lastAgent: Agent? { lock.withLock { agents.last } }
    var wantedTitles: [String] { lock.withLock { titles } }
    var exitCount: Int { lock.withLock { exits } }

    @discardableResult
    func wait(_ seconds: Double = 15, until ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ok() {
            if Date() > deadline { return false }
            _ = changed.wait(timeout: .now() + 0.2)
        }
        return true
    }
}

@Suite(.serialized) struct AgentSessionTests {
    func setUp() throws -> (dir: URL, exe: String) {
        let dir = try scratchFolder("session")
        let exe = dir.appendingPathComponent("claude")
        try fakeClaude.write(to: exe, atomically: true, encoding: .utf8)
        chmod(exe.path, 0o755)
        return (dir, exe.path)
    }

    func context(_ dir: URL, env: [String: String] = [:]) -> (String) -> LaunchContext {
        { exe in
            LaunchContext(executable: exe, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": dir.path].merging(env) { $1 },
                          claudeSettingsFile: dir.appendingPathComponent("hooks.json").path,
                          eventsFile: dir.appendingPathComponent("events.jsonl").path,
                          statusFile: dir.appendingPathComponent("status.json").path,
                          defaultAccess: .auto, meetingSeatsAcceptEdits: true)
        }
    }

    @Test func aTurnFromStartToFinish() throws {
        let (dir, exe) = try setUp()
        defer { cleanUp(dir) }
        let agent = Agent(projectID: UUID(), provider: .claude, model: "haiku", access: .manual, role: "", cwd: dir.path,
                          pendingTask: "Fix the bug")
        let s = AgentSession(agent: agent, cols: 100, rows: 30)
        let w = SessionWatch(s)
        s.start(executable: exe, context: context(dir), typeOnStart: "Fix the bug")

        // The command line is LaunchPlan's: a new session, the hooks, the model, the access, the task.
        #expect(w.wait { s.screenText().contains("FAKE ARGS") })
        // One long line, wrapped across rows.
        let screen = s.screenText().replacingOccurrences(of: "\n", with: "")
        #expect(screen.contains("--session-id \(agent.sessionID.uuidString.lowercased())"))
        #expect(screen.contains("--permission-mode manual Fix the bug"))

        // Hook events move the status the same way they do in the app.
        #expect(w.wait { w.lastState?.ask != nil })
        #expect(w.activities.starts(with: ["starting: Starting up", "idle: Ready for a task"]))
        #expect(w.activities.contains("working: Asked: Fix the bug"))
        #expect(w.activities.contains("working: Running listing files"))
        #expect(w.lastState?.status == .needsYou)
        #expect(w.lastState?.ask?.kind == .permission(tool: "Bash", detail: "rm -rf build"))
        #expect(w.lastAgent?.hasStarted == true && w.lastAgent?.pendingTask == nil)
        #expect(w.lastAgent?.title == "Fix the bug")
        #expect(w.wantedTitles == ["Fix the bug"])

        // Answering from outside presses the key on its screen and says so.
        var response: PromptResponse?
        let answered = DispatchSemaphore(value: 0)
        s.respond(.allow) { response = $0; answered.signal() }
        answered.wait()
        #expect(response == .press(["1"], status: .working, activity: "Allowed"))
        #expect(w.wait { w.lastState?.status == .done })
        #expect(s.screenText().contains("KEY: 1"))
        #expect(w.lastState?.activity == "Finished · Allowed")

        // Stopping: asleep, "Stopped", and it isn't running any more.
        s.stop(grace: 1)
        #expect(w.wait { w.exitCount == 1 })
        #expect(w.lastState?.status == .asleep && w.lastState?.activity == "Stopped")
        #expect(!s.isRunning)
        #expect(!s.screenText().contains("Session ended"))
    }

    @Test func aConversationThatCantBeReopenedStartsOverNextTime() throws {
        let (dir, exe) = try setUp()
        defer { cleanUp(dir) }
        let agent = Agent(projectID: UUID(), provider: .claude, model: "default", role: "", cwd: dir.path, hasStarted: true)
        let s = AgentSession(agent: agent)
        let w = SessionWatch(s)
        s.start(executable: exe, context: context(dir, env: ["FAKE_RESUME_FAILS": "1"]))
        #expect(w.wait { w.exitCount == 1 })
        #expect(s.screenText().replacingOccurrences(of: "\n", with: "").contains("--resume \(agent.sessionID.uuidString.lowercased())"))
        #expect(s.screenText().contains("The earlier conversation couldn't be reopened"))
        #expect(w.lastState?.activity == "Couldn't reopen its conversation")
        #expect(w.lastAgent?.hasStarted == false)
        #expect(w.lastAgent.map { $0.sessionID != agent.sessionID } == true)
    }

    @Test func aMissingCLIOrFolderIsExplained() throws {
        let (dir, _) = try setUp()
        defer { cleanUp(dir) }
        let s = AgentSession(agent: Agent(projectID: UUID(), provider: .claude, model: "default", role: "", cwd: dir.path))
        let w = SessionWatch(s)
        s.start(executable: nil, context: context(dir))
        #expect(w.wait { w.lastState != nil })
        #expect(w.lastState?.activity == "Claude Code isn't installed")
        #expect(s.screenText().contains("Claude Code isn't installed on this host."))

        let gone = AgentSession(agent: Agent(projectID: UUID(), provider: .claude, model: "default", role: "", cwd: dir.path + "/gone"))
        let w2 = SessionWatch(gone)
        gone.start(executable: "/bin/sh", context: context(dir))
        #expect(w2.wait { w2.lastState != nil })
        #expect(w2.lastState?.activity == "Its folder is missing")
    }

    @Test func aSnapshotRebuildsWhatViewersWouldSee() throws {
        let (dir, exe) = try setUp()
        defer { cleanUp(dir) }
        let s = AgentSession(agent: Agent(projectID: UUID(), provider: .claude, model: "default", role: "", cwd: dir.path), cols: 90, rows: 20)
        let w = SessionWatch(s)
        s.start(executable: exe, context: context(dir))
        #expect(w.wait { s.screenText().contains("FAKE ARGS") })
        let copy = Terminal(delegate: TerminalSnapshotTests.Quiet(), options: TerminalOptions(cols: 90, rows: 20, scrollback: 100))
        copy.feed(byteArray: s.snapshot())
        #expect(TerminalSnapshot.screenText(copy) == s.screenText())
        s.forceStop()
        #expect(w.wait { w.exitCount == 1 })
    }
}


