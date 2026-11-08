import Foundation

/// Why an agent started needing you, so the app can pick the right sound.
package enum HookCue: Sendable {
    case question, permission, error
}

/// What a Claude Code hook event means for an agent, as a list of things to do, in order.
package enum HookEffect: Equatable, Sendable {
    /// Set its status. Any status other than `.needsYou` also clears what it was asking.
    case status(AgentStatus, activity: String?, cue: HookCue)
    /// Remember what it's waiting on, so it can be answered from a tile.
    case ask(PendingAsk.Kind)
    /// Its session is up: type whatever was waiting to be typed into it.
    case typePendingInput
    /// The CLI has really begun the session: later starts resume it, and the first task is no longer pending.
    case markStarted
    /// An untitled chat got its first request: title it from that.
    case retitle(from: String)
    /// Its turn ended (a meeting moves on; a pull request it opened may now exist).
    case turnEnded
}

/// The part of an agent's state that decides what a hook event means.
package struct HookAgentState: Sendable {
    package var status: AgentStatus
    package var activity: String
    package var ask: PendingAsk.Kind?
    package var hasStarted: Bool
    package var isUntitled: Bool

    package init(status: AgentStatus, activity: String, ask: PendingAsk.Kind?, hasStarted: Bool, isUntitled: Bool) {
        self.status = status
        self.activity = activity
        self.ask = ask
        self.hasStarted = hasStarted
        self.isUntitled = isUntitled
    }
}

/// Turns Claude Code hook events into status changes. Pure: the same event and state always give the same effects,
/// and the caller (the app's store, or HiveMinds Host) carries them out.
package enum HookInterpreter {
    package static func effects(of event: [String: Any], state: HookAgentState) -> [HookEffect] {
        guard let name = event["hook_event_name"] as? String else { return [] }
        var out: [HookEffect] = []
        func status(_ s: AgentStatus, _ activity: String?, cue: HookCue = .question) { out.append(.status(s, activity: activity, cue: cue)) }
        func ask(_ kind: PendingAsk.Kind) {
            if case .questions(let q) = kind, q.isEmpty { return }
            out.append(.ask(kind))
        }
        func askToApprovePlan(_ input: [String: Any]) {
            if case .plan? = state.ask { return }
            status(.needsYou, "Wants you to approve its plan", cue: .question)
            ask(.plan((input["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        switch name {
        case "SessionStart":
            if state.status == .starting || state.status == .asleep { status(.idle, "Ready for a task") }
            out.append(.typePendingInput)
        case "UserPromptSubmit":
            if !state.hasStarted { out.append(.markStarted) }
            let prompt = (event["prompt"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            if state.isUntitled, !prompt.trimmingCharacters(in: .whitespaces).isEmpty, !prompt.hasPrefix("/") {
                out.append(.retitle(from: prompt))
            }
            status(.working, prompt.isEmpty ? "Thinking" : "Asked: \(prompt.prefix(120))")
        case "PreToolUse":
            let tool = event["tool_name"] as? String
            let input = event["tool_input"] as? [String: Any] ?? [:]
            if tool == "AskUserQuestion" {
                status(.needsYou, "Has a question for you", cue: .question)
                ask(.questions(AskQuestion.parse(input)))
            } else if tool == "ExitPlanMode" {
                askToApprovePlan(input)
            } else {
                status(.working, describeToolUse(tool ?? "a tool", input))
            }
        case "PermissionRequest":
            let tool = event["tool_name"] as? String ?? "a tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            if tool == "AskUserQuestion" {
                status(.needsYou, "Has a question for you", cue: .question)
                ask(.questions(AskQuestion.parse(input)))
            } else if tool == "ExitPlanMode" {
                askToApprovePlan(input)
            } else {
                status(.needsYou, "Wants permission to use \(tool)", cue: .permission)
                ask(.permission(tool: tool, detail: permissionDetail(tool, input)))
            }
        case "Notification":
            let type = event["notification_type"] as? String ?? ""
            let message = event["message"] as? String ?? "Waiting for you"
            if type == "idle_prompt" {
                if state.status == .working { status(.needsYou, message) }
            } else if state.ask == nil {
                // When it's already waiting on something it can be answered from a tile, that line says more.
                status(.needsYou, message, cue: type == "permission_prompt" ? .permission : .question)
            }
        case "StopFailure":
            // The turn ended on an error (an API error, a rate limit, a lost connection) rather than finishing.
            let error = (event["error"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") } ?? "an error"
            status(.needsYou, "Stopped on \(error)", cue: .error)
        case "Stop":
            status(.done, state.activity.hasPrefix("Asked:") ? "Finished" : "Finished · \(state.activity)")
            out.append(.turnEnded)
        case "SessionEnd":
            status(.asleep, "Session ended")
        default:
            break
        }
        return out
    }

    /// What a permission prompt is about, as you'd want to check it: the command itself, or the file.
    package static func permissionDetail(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Bash": (input["command"] as? String) ?? describeToolUse(tool, input)
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            (input["file_path"] as? String ?? input["notebook_path"] as? String) ?? describeToolUse(tool, input)
        case "WebFetch": (input["url"] as? String) ?? describeToolUse(tool, input)
        default: describeToolUse(tool, input)
        }
    }
}

/// What a tool call is doing, in plain words: "Editing App.swift", "Running the tests".
package func describeToolUse(_ tool: String, _ input: [String: Any]) -> String {
    func file(_ k: String) -> String { ((input[k] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "" }
    switch tool {
    case "Bash": return "Running \((input["description"] as? String) ?? (input["command"] as? String ?? "a command"))"
    case "Read": return "Reading \(file("file_path"))"
    case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
    case "Write": return "Writing \(file("file_path"))"
    case "Grep", "Glob": return "Searching the code"
    case "WebFetch", "WebSearch": return "Looking something up online"
    case "Task", "Agent": return "Handing part of the work to a helper"
    case "TodoWrite": return "Planning the steps"
    default: return "Using \(tool)"
    }
}
