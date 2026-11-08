import Foundation

// The agent model shared by the app (This Mac) and HiveMinds Host. Foundation only, so it builds on Linux.
// Everything is `package`: visible to the app, the host and the tests in this package, nowhere else.

package enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
    package var models: [String] {
        switch self {
        case .claude: ["default", "fable", "opus", "sonnet", "haiku"]
        case .codex: ["default"]
        }
    }
    /// Whether the app can follow this agent's status through hooks.
    package var reportsStatus: Bool { self == .claude }

    /// The command-line flags that set how hard the agent thinks, in this tool's own words.
    /// Agents saved before effort existed have none, and get no flag, so the tool uses its own setting.
    package func effortArgs(_ effort: Effort?) -> [String] {
        guard let effort else { return [] }
        let level = effortLevel(effort)
        switch self {
        case .claude: return ["--effort", level]
        case .codex: return ["-c", "model_reasoning_effort=\"\(level)\""]
        }
    }

    /// The name this tool uses for an effort level.
    package func effortLevel(_ effort: Effort) -> String {
        switch (self, effort) {
        // Codex's highest level is xhigh, so Max asks it for that.
        case (.codex, .max): "xhigh"
        default: effort.rawValue
        }
    }
}

/// How hard an agent thinks before answering. One scale for every provider; each maps it to its own names.
package enum Effort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high, xhigh, max
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
}

/// What an agent may do without asking you first.
package enum Access: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, manual, unrestricted
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .auto: "Auto review"
        case .manual: "Manual review"
        case .unrestricted: "Unrestricted"
        }
    }
    package var explainer: String {
        switch self {
        case .auto: "Safe actions go ahead on their own; a reviewer stops anything risky and asks you."
        case .manual: "The agent asks you before it edits a file or runs a command."
        case .unrestricted: "The agent never asks. It can change or delete anything your account can, so use it only in projects you can restore."
        }
    }

    /// The command-line flags for this level, in each tool's own words.
    package func args(for provider: Provider) -> [String] {
        switch (provider, self) {
        case (.claude, .auto): ["--permission-mode", "auto"]
        case (.claude, .manual): ["--permission-mode", "manual"]
        case (.claude, .unrestricted): ["--dangerously-skip-permissions"]
        case (.codex, .auto): ["--approve-for-me"]
        case (.codex, .manual): ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
        case (.codex, .unrestricted): ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }
}

package enum AgentStatus: String, Codable, Sendable {
    case asleep, starting, idle, working, needsYou, done

    package var label: String {
        switch self {
        case .asleep: "Asleep"
        case .starting: "Starting"
        case .idle: "Ready"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        }
    }
    /// Who needs looking at first.
    package var rank: Int {
        switch self {
        case .needsYou: 0
        case .done: 1
        case .working: 2
        case .starting: 3
        case .idle: 4
        case .asleep: 5
        }
    }
}

package struct Project: Codable, Identifiable, Hashable, Sendable {
    package var id = UUID()
    package var name: String
    package var path: String
    /// owner/name on GitHub, when known.
    package var repo: String?
    /// Tucked away in Settings > Projects. Its agents are stopped but keep their chats for when it's shown again.
    package var hidden: Bool?

    package init(id: UUID = UUID(), name: String, path: String, repo: String? = nil, hidden: Bool? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.repo = repo
        self.hidden = hidden
    }

    package var isHidden: Bool { hidden == true }
    package var isGitRepo: Bool { FileManager.default.fileExists(atPath: path + "/.git") }
}

/// The pull request for an agent's branch, once there is one.
package struct PullRequestRef: Codable, Hashable, Sendable {
    package var number: Int
    package var url: String
    /// OPEN, MERGED or CLOSED, as GitHub says it.
    package var state: String

    package init(number: Int, url: String, state: String) {
        self.number = number
        self.url = url
        self.state = state
    }

    package var label: String {
        switch state {
        case "MERGED": "Merged"
        case "CLOSED": "Closed"
        default: "Open"
        }
    }
}

/// The GitHub issue an agent was started on. Its pull request says "Fixes #number".
package struct IssueRef: Codable, Hashable, Sendable {
    /// owner/name
    package var repo: String
    package var number: Int
    package var title: String
    package var url: String

    package init(repo: String, number: Int, title: String, url: String) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
    }
}

package struct Agent: Codable, Identifiable, Hashable, Sendable {
    package var id = UUID()
    package var projectID: UUID
    /// What the chat is about, written from its first request. Agents have no names.
    package var title = Agent.untitled
    package var provider: Provider
    package var model: String
    /// How hard it thinks. Nil for agents from before this setting existed.
    package var effort: Effort?
    /// What it may do without asking. Nil for agents from before this setting existed. Meeting seats
    /// from before seats had their own level follow the default in Settings > Agents.
    package var access: Access?
    /// Extra instructions appended to the agent's system prompt.
    package var role: String
    /// Where it works: the project folder, or its own worktree.
    package var cwd: String
    /// Its own branch, when it works in a worktree.
    package var branch: String?
    package var sessionID = UUID()
    /// Set once the CLI has really begun the session, so later starts resume it.
    package var hasStarted = false
    /// The first prompt, sent when the agent first starts.
    package var pendingTask: String?
    package var createdAt = Date()
    /// Set for an agent sitting in a meeting. Those show in the meeting room, not in the project's workspace.
    package var meetingID: UUID?
    /// The pull request for its branch, once there is one.
    package var pullRequest: PullRequestRef?
    /// The GitHub issue it was started on, if any.
    package var issue: IssueRef?
    /// Starts in Claude Code's plan mode: it works out a plan and waits for you to approve it before changing anything.
    /// Only used on the first start; a resumed agent picks up with its normal access.
    package var startsInPlan: Bool?

    package static let untitled = "New chat"
    package var isUntitled: Bool { title == Agent.untitled }

    /// The same as the memberwise initializer the app used before this type moved here.
    package init(id: UUID = UUID(), projectID: UUID, title: String = Agent.untitled, provider: Provider, model: String,
                 effort: Effort? = nil, access: Access? = nil, role: String, cwd: String, branch: String? = nil,
                 sessionID: UUID = UUID(), hasStarted: Bool = false, pendingTask: String? = nil, createdAt: Date = Date(),
                 meetingID: UUID? = nil, pullRequest: PullRequestRef? = nil, issue: IssueRef? = nil, startsInPlan: Bool? = nil) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.provider = provider
        self.model = model
        self.effort = effort
        self.access = access
        self.role = role
        self.cwd = cwd
        self.branch = branch
        self.sessionID = sessionID
        self.hasStarted = hasStarted
        self.pendingTask = pendingTask
        self.createdAt = createdAt
        self.meetingID = meetingID
        self.pullRequest = pullRequest
        self.issue = issue
        self.startsInPlan = startsInPlan
    }

    // Saved as "name", which is what earlier versions called the title.
    enum CodingKeys: String, CodingKey {
        case id, projectID, title = "name", provider, model, effort, access, role, cwd, branch, sessionID, hasStarted, pendingTask, createdAt, meetingID, pullRequest, issue, startsInPlan
    }

    /// A quick title from the request itself, used until a better one comes back.
    package static func roughTitle(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace)
        var out = ""
        for w in words {
            if out.count + w.count > 48 { return out.isEmpty ? String(w.prefix(48)) + "…" : out + "…" }
            out += out.isEmpty ? String(w) : " " + w
        }
        return out.isEmpty ? Agent.untitled : out
    }
}

package struct LiveState: Sendable {
    package var status: AgentStatus = .asleep
    package var activity: String = ""
    package var updated = Date()
    /// What it stopped to ask, while it waits, so it can be answered from a tile.
    package var ask: PendingAsk?

    package init(status: AgentStatus = .asleep, activity: String = "", updated: Date = Date(), ask: PendingAsk? = nil) {
        self.status = status
        self.activity = activity
        self.updated = updated
        self.ask = ask
    }

    /// A new status, and what it's doing if that's given. Any status but `.needsYou` drops what it was asking.
    package mutating func set(_ status: AgentStatus, _ activity: String? = nil, at time: Date = Date()) {
        self.status = status
        if status != .needsYou { ask = nil }
        if let activity { self.activity = activity }
        updated = time
    }
}

/// A permission prompt or question an agent is waiting on, read from its hook event.
package struct PendingAsk: Identifiable, Sendable {
    package let id = UUID()
    package var kind: Kind

    package init(kind: Kind) { self.kind = kind }

    package enum Kind: Equatable, Sendable {
        /// `detail` is what it wants to do: the command, or the file it wants to change.
        case permission(tool: String, detail: String)
        case questions([AskQuestion])
        /// It finished planning (plan mode) and wants the plan approved before it starts work.
        case plan(String)
    }
}

/// Your answer to one question: one of its options, or your own words.
package enum QuestionAnswer: Equatable, Sendable {
    case option(Int)
    case text(String)
}

/// One question from Claude Code's AskUserQuestion tool.
package struct AskQuestion: Equatable, Sendable {
    package var header: String
    package var question: String
    package var options: [String]
    package var multiSelect: Bool

    package init(header: String, question: String, options: [String], multiSelect: Bool) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions in an AskUserQuestion tool call's input.
    package static func parse(_ input: [String: Any]) -> [AskQuestion] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return AskQuestion(header: q["header"] as? String ?? "", question: text, options: options,
                               multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }
}

package func slugify(_ s: String) -> String {
    let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(lowered).split(separator: "-").joined(separator: "-").prefix(32).description
}
