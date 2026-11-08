import Foundation
import Testing
@testable import HiveMindsCore

/// The command lines below are what the app built before the launch code moved into HiveMindsCore
/// (Terminals.start, HiveMinds 1.7). They must not change by accident.
@Suite struct LaunchPlanTests {
    let project = UUID()
    let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func context(_ exe: String = "/usr/local/bin/claude") -> LaunchContext {
        LaunchContext(executable: exe, baseEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/me"],
                      signInEnvironment: [:], codexSignInArgs: ["-c", "model_provider=\"x\""],
                      claudeSettingsFile: "/s/claude-hooks.json", eventsFile: "/s/events/a.jsonl", statusFile: "/s/status/a.json",
                      defaultAccess: .manual, meetingSeatsAcceptEdits: true)
    }

    func claude(_ change: (inout Agent) -> Void = { _ in }) -> Agent {
        var a = Agent(projectID: project, provider: .claude, model: "haiku", effort: .high, access: .auto,
                      role: "", cwd: "/p", sessionID: session, pendingTask: "Fix the bug")
        change(&a)
        return a
    }

    @Test func newClaudeAgentStartsItsSessionWithTheTask() {
        let p = LaunchPlan.make(for: claude(), context())
        #expect(p.executable == "/usr/local/bin/claude")
        #expect(p.directory == "/p")
        #expect(p.arguments == ["--session-id", "11111111-2222-3333-4444-555555555555", "--settings", "/s/claude-hooks.json",
                                "--model", "haiku", "--effort", "high", "--permission-mode", "auto", "Fix the bug"])
        #expect(!p.resumes && !p.startsTaskNow)
        #expect(p.status == .starting && p.activity == "Starting up")
    }

    @Test func startedClaudeAgentResumesWithoutTheTask() {
        let p = LaunchPlan.make(for: claude { $0.hasStarted = true }, context())
        #expect(p.arguments == ["--resume", "11111111-2222-3333-4444-555555555555", "--settings", "/s/claude-hooks.json",
                                "--model", "haiku", "--effort", "high", "--permission-mode", "auto"])
        #expect(p.resumes)
    }

    @Test func defaultModelOldAgentsAndRoles() {
        let p = LaunchPlan.make(for: claude { $0.model = "default"; $0.effort = nil; $0.access = nil; $0.role = "Be brief"; $0.pendingTask = nil }, context())
        #expect(p.arguments == ["--session-id", "11111111-2222-3333-4444-555555555555", "--settings", "/s/claude-hooks.json",
                                "--append-system-prompt", "Be brief"])
    }

    @Test func planModeReplacesTheAccessModeOnFirstStartOnly() {
        let first = LaunchPlan.make(for: claude { $0.startsInPlan = true; $0.access = .unrestricted }, context())
        #expect(first.arguments.suffix(4) == ["--permission-mode", "plan", "--allow-dangerously-skip-permissions", "Fix the bug"])
        let later = LaunchPlan.make(for: claude { $0.startsInPlan = true; $0.access = .unrestricted; $0.hasStarted = true }, context())
        #expect(later.arguments.last == "--dangerously-skip-permissions")
    }

    @Test func meetingSeatsUseTheDefaultAccessAndMayAcceptEdits() {
        let seat = LaunchPlan.make(for: claude { $0.access = nil; $0.meetingID = UUID(); $0.pendingTask = nil }, context())
        #expect(seat.arguments.suffix(4) == ["--permission-mode", "manual", "--permission-mode", "acceptEdits"])
        var c = context()
        c.meetingSeatsAcceptEdits = false
        let strict = LaunchPlan.make(for: claude { $0.access = nil; $0.meetingID = UUID(); $0.pendingTask = nil }, c)
        #expect(strict.arguments.suffix(2) == ["--permission-mode", "manual"])
    }

    @Test func environmentCarriesTheAgentAndItsFiles() {
        var c = context()
        c.signInEnvironment = ["HIVEMINDS_ANTHROPIC_KEY": "k"]
        let a = claude()
        let env = LaunchPlan.make(for: a, c).environment
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["TERM"] == "xterm-256color" && env["COLORTERM"] == "truecolor" && env["LANG"] == "en_US.UTF-8")
        #expect(env["HIVEMINDS_AGENT"] == a.id.uuidString)
        #expect(env["HIVEMINDS_EVENTS"] == "/s/events/a.jsonl" && env["HIVEMINDS_STATUS"] == "/s/status/a.json")
        #expect(env["HIVEMINDS_ANTHROPIC_KEY"] == "k")
    }

    @Test func codexTakesItsTaskOnTheCommandLine() {
        var a = claude()
        a.provider = .codex
        a.model = "default"
        a.effort = .max
        a.access = .manual
        let p = LaunchPlan.make(for: a, context("/usr/local/bin/codex"))
        #expect(p.arguments == ["-c", "model_provider=\"x\"", "-c", "model_reasoning_effort=\"xhigh\"",
                                "--sandbox", "read-only", "--ask-for-approval", "on-request", "Fix the bug"])
        #expect(p.startsTaskNow && p.status == .idle && p.activity == "Running in its terminal")
        #expect(p.environment["HIVEMINDS_EVENTS"] == nil)
        a.pendingTask = nil
        #expect(!LaunchPlan.make(for: a, context()).startsTaskNow)
    }
}
