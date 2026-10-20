import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
    var models: [String] {
        switch self {
        case .claude: ["default", "fable", "opus", "sonnet", "haiku"]
        case .codex: ["default"]
        }
    }
    /// Whether the app can follow this agent's status through hooks.
    var reportsStatus: Bool { self == .claude }

    /// The command-line flags that set how hard the agent thinks, in this tool's own words.
    /// Agents saved before effort existed have none, and get no flag, so the tool uses its own setting.
    func effortArgs(_ effort: Effort?) -> [String] {
        guard let effort else { return [] }
        let level = effortLevel(effort)
        switch self {
        case .claude: return ["--effort", level]
        case .codex: return ["-c", "model_reasoning_effort=\"\(level)\""]
        }
    }

    /// The name this tool uses for an effort level.
    func effortLevel(_ effort: Effort) -> String {
        switch (self, effort) {
        // Codex's highest level is xhigh, so Max asks it for that.
        case (.codex, .max): "xhigh"
        default: effort.rawValue
        }
    }
}

/// How hard an agent thinks before answering. One scale for every provider; each maps it to its own names.
enum Effort: String, Codable, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
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
enum Access: String, Codable, CaseIterable, Identifiable {
    case auto, manual, unrestricted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto review"
        case .manual: "Manual review"
        case .unrestricted: "Unrestricted"
        }
    }
    var explainer: String {
        switch self {
        case .auto: "Safe actions go ahead on their own; a reviewer stops anything risky and asks you."
        case .manual: "The agent asks you before it edits a file or runs a command."
        case .unrestricted: "The agent never asks. It can change or delete anything your account can, so use it only in projects you can restore."
        }
    }

    /// The command-line flags for this level, in each tool's own words.
    func args(for provider: Provider) -> [String] {
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

enum AgentStatus: String, Codable {
    case asleep, starting, idle, working, needsYou, done

    var label: String {
        switch self {
        case .asleep: "Asleep"
        case .starting: "Starting"
        case .idle: "Ready"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        }
    }
    var color: Color {
        switch self {
        case .asleep: .secondary
        case .starting: .secondary
        case .idle: .purple
        case .working: .blue
        case .needsYou: .orange
        case .done: .green
        }
    }
    /// Who needs looking at first.
    var rank: Int {
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

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    /// owner/name on GitHub, when known.
    var repo: String?

    var isGitRepo: Bool { FileManager.default.fileExists(atPath: path + "/.git") }
}

struct Agent: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
    /// What the chat is about, written from its first request. Agents have no names.
    var title = Agent.untitled
    var provider: Provider
    var model: String
    /// How hard it thinks. Nil for agents from before this setting existed.
    var effort: Effort?
    /// What it may do without asking. Nil for agents from before this setting existed. Meeting seats
    /// from before seats had their own level follow the default in Settings > Agents.
    var access: Access?
    /// Extra instructions appended to the agent's system prompt.
    var role: String
    /// Where it works: the project folder, or its own worktree.
    var cwd: String
    /// Its own branch, when it works in a worktree.
    var branch: String?
    var sessionID = UUID()
    /// Set once the CLI has really begun the session, so later starts resume it.
    var hasStarted = false
    /// The first prompt, sent when the agent first starts.
    var pendingTask: String?
    var createdAt = Date()
    /// Set for an agent sitting in a meeting. Those show in the meeting room, not in the project's workspace.
    var meetingID: UUID?
    /// The pull request for its branch, once there is one.
    var pullRequest: PullRequestRef?

    static let untitled = "New chat"
    var isUntitled: Bool { title == Agent.untitled }

    // Saved as "name", which is what earlier versions called the title.
    enum CodingKeys: String, CodingKey {
        case id, projectID, title = "name", provider, model, effort, access, role, cwd, branch, sessionID, hasStarted, pendingTask, createdAt, meetingID, pullRequest
    }

    /// A quick title from the request itself, used until a better one comes back.
    static func roughTitle(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isWhitespace)
        var out = ""
        for w in words {
            if out.count + w.count > 48 { return out.isEmpty ? String(w.prefix(48)) + "…" : out + "…" }
            out += out.isEmpty ? String(w) : " " + w
        }
        return out.isEmpty ? Agent.untitled : out
    }
}

struct LiveState {
    var status: AgentStatus = .asleep
    var activity: String = ""
    var updated = Date()
    /// What it stopped to ask, while it waits, so it can be answered from a tile.
    var ask: PendingAsk?
}

/// A permission prompt or question an agent is waiting on, read from its hook event.
struct PendingAsk: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        /// `detail` is what it wants to do: the command, or the file it wants to change.
        case permission(tool: String, detail: String)
        case questions([AskQuestion])
    }
}

/// Your answer to one question: one of its options, or your own words.
enum QuestionAnswer {
    case option(Int)
    case text(String)
}

/// One question from Claude Code's AskUserQuestion tool.
struct AskQuestion {
    var header: String
    var question: String
    var options: [String]
    var multiSelect: Bool

    /// The questions in an AskUserQuestion tool call's input.
    static func parse(_ input: [String: Any]) -> [AskQuestion] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return AskQuestion(header: q["header"] as? String ?? "", question: text, options: options,
                               multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case agents = "Agents", meetings = "Meetings", github = "GitHub"
    var id: String { rawValue }
}

enum SidebarItem: Hashable {
    case overview
    /// A project's workspace on its Canvas tab.
    case project(UUID)
    case agent(UUID)
    case browser(UUID)
    /// A shell (terminal) open as a tab in a project's workspace.
    case shell(UUID)
    /// A meeting's overview, opened as a tab in its project's workspace.
    case meeting(UUID)
}

/// A web page open as a tab in a project's workspace.
struct BrowserTab: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
    var url = ""
    var title = ""
}

/// A shell open as a tab in a project's workspace, started in the project's folder.
struct ShellTab: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
}

func slugify(_ s: String) -> String {
    let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(lowered).split(separator: "-").joined(separator: "-").prefix(32).description
}
