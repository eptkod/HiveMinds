import Foundation

/// Constants of the HiveMinds Host protocol (docs/HOST-PROTOCOL.md).
package enum HostProtocol {
    /// The protocol version. Peers with different versions don't talk (`incompatible`).
    package static let version = 1
    package static let defaultPort = 7420
    /// The WebSocket path.
    package static let path = "/hiveminds/v1"
    /// The only `Host` header the host accepts (DNS rebinding defence).
    package static let hostHeader = "hiveminds"
    /// The Bonjour/Avahi service type.
    package static let serviceType = "_hiveminds._tcp"
    /// The largest message either side accepts.
    package static let maxMessageSize = 16 << 20
    /// Seconds a connection has to say `hello`, and to finish pairing.
    package static let helloTimeout: TimeInterval = 10
    package static let pairingTimeout: TimeInterval = 120
    /// Seconds without typing after which the controller lets go.
    package static let controlTimeout: TimeInterval = 30
}

/// A paired device, as others see it.
package struct DeviceInfo: Codable, Hashable, Sendable {
    package var id: String
    package var name: String
    package init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

package struct ProjectInfo: Codable, Hashable, Sendable {
    package var id: UUID
    package var name: String
    package var isGitRepo: Bool
    package var repo: String?
    package init(id: UUID, name: String, isGitRepo: Bool, repo: String? = nil) {
        self.id = id
        self.name = name
        self.isGitRepo = isGitRepo
        self.repo = repo
    }
}

package struct QuestionInfo: Codable, Hashable, Sendable {
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
}

/// What an agent is waiting on.
package enum AskInfo: Codable, Hashable, Sendable {
    case permission(tool: String, detail: String)
    case questions([QuestionInfo])
    case plan(String)

    private enum Keys: String, CodingKey { case kind, tool, detail, questions, plan }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "permission": self = .permission(tool: try c.decode(String.self, forKey: .tool), detail: try c.decode(String.self, forKey: .detail))
        case "questions": self = .questions(try c.decode([QuestionInfo].self, forKey: .questions))
        case "plan": self = .plan(try c.decode(String.self, forKey: .plan))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown ask kind \(other)")
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .permission(let tool, let detail):
            try c.encode("permission", forKey: .kind)
            try c.encode(tool, forKey: .tool)
            try c.encode(detail, forKey: .detail)
        case .questions(let q):
            try c.encode("questions", forKey: .kind)
            try c.encode(q, forKey: .questions)
        case .plan(let p):
            try c.encode("plan", forKey: .kind)
            try c.encode(p, forKey: .plan)
        }
    }
}

package struct AgentInfo: Codable, Hashable, Sendable {
    package var id: UUID
    package var projectId: UUID
    package var title: String
    package var provider: String
    package var model: String
    package var effort: String?
    package var access: String?
    package var branch: String?
    package var createdAt: Double
    package var startedBy: DeviceInfo?
    package var status: String
    package var activity: String
    package var ask: AskInfo?
    package var running: Bool
    package var cols: Int
    package var rows: Int
    package var viewers: [DeviceInfo]
    package var controller: DeviceInfo?
    /// For agents in `history`: when they were deleted.
    package var endedAt: Double?

    package init(id: UUID, projectId: UUID, title: String, provider: String, model: String, effort: String? = nil,
                 access: String? = nil, branch: String? = nil, createdAt: Double, startedBy: DeviceInfo? = nil,
                 status: String, activity: String, ask: AskInfo? = nil, running: Bool, cols: Int, rows: Int,
                 viewers: [DeviceInfo] = [], controller: DeviceInfo? = nil, endedAt: Double? = nil) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.provider = provider
        self.model = model
        self.effort = effort
        self.access = access
        self.branch = branch
        self.createdAt = createdAt
        self.startedBy = startedBy
        self.status = status
        self.activity = activity
        self.ask = ask
        self.running = running
        self.cols = cols
        self.rows = rows
        self.viewers = viewers
        self.controller = controller
        self.endedAt = endedAt
    }
}

package struct ChangedFileInfo: Codable, Hashable, Sendable {
    package var path: String
    package var added: Int?
    package var removed: Int?
    package var untracked: Bool
    package init(path: String, added: Int?, removed: Int?, untracked: Bool) {
        self.path = path
        self.added = added
        self.removed = removed
        self.untracked = untracked
    }
}

package struct DiffLineInfo: Codable, Hashable, Sendable {
    package var kind: String
    package var text: String
    package init(kind: String, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// One answer to one question: an option's index, or your own words.
package enum AnswerInfo: Codable, Hashable, Sendable {
    case option(Int)
    case text(String)

    private enum Keys: String, CodingKey { case option, text }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let n = try c.decodeIfPresent(Int.self, forKey: .option) { self = .option(n) }
        else { self = .text(try c.decode(String.self, forKey: .text)) }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .option(let n): try c.encode(n, forKey: .option)
        case .text(let t): try c.encode(t, forKey: .text)
        }
    }
}
