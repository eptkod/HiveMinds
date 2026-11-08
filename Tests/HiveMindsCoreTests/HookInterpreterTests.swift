import Foundation
import Testing
@testable import HiveMindsCore

/// What each Claude Code hook event does to an agent, as the app's store did it before this moved to HiveMindsCore.
@Suite struct HookInterpreterTests {
    func state(_ status: AgentStatus = .working, activity: String = "", ask: PendingAsk.Kind? = nil,
               hasStarted: Bool = true, isUntitled: Bool = false) -> HookAgentState {
        HookAgentState(status: status, activity: activity, ask: ask, hasStarted: hasStarted, isUntitled: isUntitled)
    }

    func effects(_ event: [String: Any], _ s: HookAgentState) -> [HookEffect] { HookInterpreter.effects(of: event, state: s) }

    @Test func ignoresEventsWithoutAName() {
        #expect(effects(["prompt": "hi"], state()).isEmpty)
        #expect(effects(["hook_event_name": "SomethingNew"], state()).isEmpty)
    }

    @Test func sessionStartMakesAStartingAgentReady() {
        #expect(effects(["hook_event_name": "SessionStart"], state(.starting)) ==
                [.status(.idle, activity: "Ready for a task", cue: .question), .typePendingInput])
        #expect(effects(["hook_event_name": "SessionStart"], state(.working)) == [.typePendingInput])
    }

    @Test func firstPromptStartsTitlesAndWorks() {
        let e = effects(["hook_event_name": "UserPromptSubmit", "prompt": "Fix the\nlogin"], state(.idle, hasStarted: false, isUntitled: true))
        #expect(e == [.markStarted, .retitle(from: "Fix the login"), .status(.working, activity: "Asked: Fix the login", cue: .question)])
        // Slash commands and titled chats keep their title; an empty prompt reads "Thinking".
        #expect(effects(["hook_event_name": "UserPromptSubmit", "prompt": "/clear"], state(isUntitled: true)) ==
                [.status(.working, activity: "Asked: /clear", cue: .question)])
        #expect(effects(["hook_event_name": "UserPromptSubmit"], state()) == [.status(.working, activity: "Thinking", cue: .question)])
    }

    @Test func toolUseDescribesWhatItsDoing() {
        let e = effects(["hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/p/App.swift"]], state())
        #expect(e == [.status(.working, activity: "Editing App.swift", cue: .question)])
    }

    @Test func questionsAreAskedAndEmptyOnesIgnored() {
        let input: [String: Any] = ["questions": [["header": "DB", "question": "Which one?", "options": [["label": "A"], ["label": "B"]]]]]
        let e = effects(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": input], state())
        #expect(e == [.status(.needsYou, activity: "Has a question for you", cue: .question),
                      .ask(.questions([AskQuestion(header: "DB", question: "Which one?", options: ["A", "B"], multiSelect: false)]))])
        let empty = effects(["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": [:]], state())
        #expect(empty == [.status(.needsYou, activity: "Has a question for you", cue: .question)])
    }

    @Test func planApprovalIsAskedOnce() {
        let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "tool_input": ["plan": "  1. Do it\n"]]
        #expect(effects(event, state()) == [.status(.needsYou, activity: "Wants you to approve its plan", cue: .question), .ask(.plan("1. Do it"))])
        #expect(effects(event, state(.needsYou, ask: .plan("1. Do it"))).isEmpty)
    }

    @Test func permissionRequestsShowTheCommand() {
        let e = effects(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]], state())
        #expect(e == [.status(.needsYou, activity: "Wants permission to use Bash", cue: .permission),
                      .ask(.permission(tool: "Bash", detail: "rm -rf build"))])
    }

    @Test func notifications() {
        let idle: [String: Any] = ["hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "Waiting"]
        #expect(effects(idle, state(.working)) == [.status(.needsYou, activity: "Waiting", cue: .question)])
        #expect(effects(idle, state(.done)).isEmpty)
        let perm: [String: Any] = ["hook_event_name": "Notification", "notification_type": "permission_prompt"]
        #expect(effects(perm, state()) == [.status(.needsYou, activity: "Waiting for you", cue: .permission)])
        // Already waiting on something answerable from a tile: that says more.
        #expect(effects(perm, state(.needsYou, ask: .plan("x"))).isEmpty)
    }

    @Test func stopsAndFailures() {
        #expect(effects(["hook_event_name": "Stop"], state(activity: "Asked: fix it")) ==
                [.status(.done, activity: "Finished", cue: .question), .turnEnded])
        #expect(effects(["hook_event_name": "Stop"], state(activity: "Editing App.swift")) ==
                [.status(.done, activity: "Finished · Editing App.swift", cue: .question), .turnEnded])
        #expect(effects(["hook_event_name": "StopFailure", "error": "rate_limit"], state()) ==
                [.status(.needsYou, activity: "Stopped on rate limit", cue: .error)])
        #expect(effects(["hook_event_name": "SessionEnd"], state()) == [.status(.asleep, activity: "Session ended", cue: .question)])
    }
}
