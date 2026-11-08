import Foundation

// The JSON messages of docs/HOST-PROTOCOL.md §2. Each is an object with a `type`; requests and their replies
// also carry the client's `id`. Unknown fields are ignored when decoding.

private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct Empty: Codable {}

private func writeTag(_ encoder: Encoder, _ type: String, id: String? = nil) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(type, forKey: Key("type"))
    if let id { try c.encode(id, forKey: Key("id")) }
}

private func readTag(_ decoder: Decoder) throws -> (type: String, id: String?) {
    let c = try decoder.container(keyedBy: Key.self)
    return (try c.decode(String.self, forKey: Key("type")), try c.decodeIfPresent(String.self, forKey: Key("id")))
}

// MARK: Client → host

package struct Hello: Codable, Sendable {
    package struct Device: Codable, Sendable {
        package var name: String
        package init(name: String) { self.name = name }
    }
    package var `protocol`: Int
    package var client: String
    package var device: Device
    package var token: String?
    package init(protocol: Int = HostProtocol.version, client: String, deviceName: String, token: String?) {
        self.protocol = `protocol`
        self.client = client
        self.device = Device(name: deviceName)
        self.token = token
    }
}

package struct PairStart: Codable, Sendable {
    package var spake: String
    package var device: Hello.Device
    package init(spake: String, deviceName: String) {
        self.spake = spake
        self.device = Hello.Device(name: deviceName)
    }
}

package struct PairConfirm: Codable, Sendable {
    package var proof: String
    package init(proof: String) { self.proof = proof }
}

package struct AgentRef: Codable, Sendable {
    package var agentId: UUID
    package init(_ id: UUID) { agentId = id }
}

package struct SizedAgentRef: Codable, Sendable {
    package var agentId: UUID
    package var cols: Int
    package var rows: Int
    package init(_ id: UUID, cols: Int, rows: Int) {
        agentId = id
        self.cols = cols
        self.rows = rows
    }
}

package struct CreateAgent: Codable, Sendable {
    package var projectId: UUID
    package var provider: String
    package var model: String
    package var effort: String
    package var access: String
    package var planMode: Bool
    package var role: String
    package var task: String
    package var ownBranch: Bool
    package init(projectId: UUID, provider: String = "claude", model: String = "default", effort: String = "medium",
                 access: String = "auto", planMode: Bool = false, role: String = "", task: String, ownBranch: Bool) {
        self.projectId = projectId
        self.provider = provider
        self.model = model
        self.effort = effort
        self.access = access
        self.planMode = planMode
        self.role = role
        self.task = task
        self.ownBranch = ownBranch
    }
}

package struct TypeText: Codable, Sendable {
    package var agentId: UUID
    package var text: String
    package init(_ id: UUID, text: String) {
        agentId = id
        self.text = text
    }
}

package struct Answer: Codable, Sendable {
    package var agentId: UUID
    /// allow, decline, approvePlan, keepPlanning, answer
    package var action: String
    package var feedback: String?
    package var answers: [AnswerInfo]?
    package init(_ id: UUID, action: String, feedback: String? = nil, answers: [AnswerInfo]? = nil) {
        agentId = id
        self.action = action
        self.feedback = feedback
        self.answers = answers
    }
}

package struct DiffRequest: Codable, Sendable {
    package var agentId: UUID
    package var path: String
    package var baseRef: String
    package var untracked: Bool
    package init(_ id: UUID, path: String, baseRef: String, untracked: Bool) {
        agentId = id
        self.path = path
        self.baseRef = baseRef
        self.untracked = untracked
    }
}

package enum Request: Sendable {
    case listProjects, listAgents, history
    case createAgent(CreateAgent)
    case startAgent(AgentRef), stopAgent(AgentRef), restartAgent(AgentRef), deleteAgent(AgentRef)
    case attach(AgentRef), detach(AgentRef), changes(AgentRef)
    case takeControl(SizedAgentRef), resize(SizedAgentRef)
    case typeText(TypeText)
    case answer(Answer)
    case diff(DiffRequest)

    package var name: String {
        switch self {
        case .listProjects: "listProjects"
        case .listAgents: "listAgents"
        case .history: "history"
        case .createAgent: "createAgent"
        case .startAgent: "startAgent"
        case .stopAgent: "stopAgent"
        case .restartAgent: "restartAgent"
        case .deleteAgent: "deleteAgent"
        case .attach: "attach"
        case .detach: "detach"
        case .changes: "changes"
        case .takeControl: "takeControl"
        case .resize: "resize"
        case .typeText: "typeText"
        case .answer: "answer"
        case .diff: "diff"
        }
    }

    /// The agent it's about, if any.
    package var agentID: UUID? {
        switch self {
        case .listProjects, .listAgents, .history, .createAgent: nil
        case .startAgent(let r), .stopAgent(let r), .restartAgent(let r), .deleteAgent(let r), .attach(let r), .detach(let r), .changes(let r): r.agentId
        case .takeControl(let r), .resize(let r): r.agentId
        case .typeText(let t): t.agentId
        case .answer(let a): a.agentId
        case .diff(let d): d.agentId
        }
    }
}

package enum ClientMessage: Codable, Sendable {
    case hello(Hello)
    case pairStart(PairStart)
    case pairConfirm(PairConfirm)
    case request(id: String, Request)
    /// A request type this side doesn't know (from a newer peer), so it can be answered `unknownRequest`.
    case unknown(type: String, id: String?)

    package init(from decoder: Decoder) throws {
        let (type, id) = try readTag(decoder)
        func r(_ req: Request) throws -> ClientMessage {
            guard let id else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(type) needs an id")) }
            return .request(id: id, req)
        }
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "pairStart": self = .pairStart(try PairStart(from: decoder))
        case "pairConfirm": self = .pairConfirm(try PairConfirm(from: decoder))
        case "listProjects": self = try r(.listProjects)
        case "listAgents": self = try r(.listAgents)
        case "history": self = try r(.history)
        case "createAgent": self = try r(.createAgent(try CreateAgent(from: decoder)))
        case "startAgent": self = try r(.startAgent(try AgentRef(from: decoder)))
        case "stopAgent": self = try r(.stopAgent(try AgentRef(from: decoder)))
        case "restartAgent": self = try r(.restartAgent(try AgentRef(from: decoder)))
        case "deleteAgent": self = try r(.deleteAgent(try AgentRef(from: decoder)))
        case "attach": self = try r(.attach(try AgentRef(from: decoder)))
        case "detach": self = try r(.detach(try AgentRef(from: decoder)))
        case "changes": self = try r(.changes(try AgentRef(from: decoder)))
        case "takeControl": self = try r(.takeControl(try SizedAgentRef(from: decoder)))
        case "resize": self = try r(.resize(try SizedAgentRef(from: decoder)))
        case "typeText": self = try r(.typeText(try TypeText(from: decoder)))
        case "answer": self = try r(.answer(try Answer(from: decoder)))
        case "diff": self = try r(.diff(try DiffRequest(from: decoder)))
        default: self = .unknown(type: type, id: id)
        }
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let m): try writeTag(encoder, "hello"); try m.encode(to: encoder)
        case .pairStart(let m): try writeTag(encoder, "pairStart"); try m.encode(to: encoder)
        case .pairConfirm(let m): try writeTag(encoder, "pairConfirm"); try m.encode(to: encoder)
        case .unknown(let type, let id): try writeTag(encoder, type, id: id)
        case .request(let id, let req):
            try writeTag(encoder, req.name, id: id)
            switch req {
            case .listProjects, .listAgents, .history: break
            case .createAgent(let m): try m.encode(to: encoder)
            case .startAgent(let m), .stopAgent(let m), .restartAgent(let m), .deleteAgent(let m), .attach(let m), .detach(let m), .changes(let m):
                try m.encode(to: encoder)
            case .takeControl(let m), .resize(let m): try m.encode(to: encoder)
            case .typeText(let m): try m.encode(to: encoder)
            case .answer(let m): try m.encode(to: encoder)
            case .diff(let m): try m.encode(to: encoder)
            }
        }
    }
}

// MARK: Host → client

package struct Welcome: Codable, Sendable {
    package var `protocol`: Int
    package var hostId: String
    package var hostName: String
    package var hostVersion: String
    package var device: DeviceInfo
    package init(hostId: String, hostName: String, hostVersion: String, device: DeviceInfo) {
        self.protocol = HostProtocol.version
        self.hostId = hostId
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.device = device
    }
}

package struct PairingRequired: Codable, Sendable {
    package var `protocol`: Int
    package var hostId: String
    /// noToken or unknownToken
    package var reason: String
    package init(hostId: String, reason: String) {
        self.protocol = HostProtocol.version
        self.hostId = hostId
        self.reason = reason
    }
}

package struct Incompatible: Codable, Sendable {
    package var `protocol`: Int
    /// "host" when the host is older, "app" when the app is.
    package var update: String
    package var message: String
    package init(update: String, message: String) {
        self.protocol = HostProtocol.version
        self.update = update
        self.message = message
    }
}

package struct PairChallenge: Codable, Sendable {
    package var spake: String
    package init(spake: String) { self.spake = spake }
}

package struct Paired: Codable, Sendable {
    package var token: String
    package var hostProof: String
    package var device: DeviceInfo
    package init(token: String, hostProof: String, device: DeviceInfo) {
        self.token = token
        self.hostProof = hostProof
        self.device = device
    }
}

/// A reply's fields. Which are set depends on the request (docs/HOST-PROTOCOL.md §2.4).
package struct Reply: Codable, Sendable {
    package var projects: [ProjectInfo]?
    package var agents: [AgentInfo]?
    package var agent: AgentInfo?
    package var keptFolder: Bool?
    package var cols: Int?
    package var rows: Int?
    package var activity: String?
    package var base: String?
    package var baseRef: String?
    package var onlyItsOwn: Bool?
    package var files: [ChangedFileInfo]?
    package var lines: [DiffLineInfo]?
    package var cut: Bool?
    package init() {}
}

package struct ErrorInfo: Codable, Sendable, Error {
    package var code: String
    package var message: String
    package var triesLeft: Int?
    package var controller: DeviceInfo?
    package init(_ code: String, _ message: String, triesLeft: Int? = nil, controller: DeviceInfo? = nil) {
        self.code = code
        self.message = message
        self.triesLeft = triesLeft
        self.controller = controller
    }
}

package enum Event: Sendable {
    case agentUpdated(AgentInfo)
    case agentRemoved(UUID)
    case projectsChanged([ProjectInfo])
    case promptResolved(agentId: UUID, by: DeviceInfo, activity: String)
    case viewers(agentId: UUID, viewers: [DeviceInfo])
    case controller(agentId: UUID, controller: DeviceInfo?, tookOverFrom: DeviceInfo?)
    case resized(agentId: UUID, cols: Int, rows: Int)
    case inputRefused(agentId: UUID, controller: DeviceInfo)
    case detached(agentId: UUID, reason: String)
    case deviceRevoked
    case hostStopping(reason: String, message: String)
}

package enum HostMessage: Codable, Sendable {
    case welcome(Welcome)
    case pairingRequired(PairingRequired)
    case incompatible(Incompatible)
    case pairChallenge(PairChallenge)
    case pairWaiting
    case paired(Paired)
    case reply(id: String, Reply)
    case error(id: String?, ErrorInfo)
    case event(Event)
    case unknown(type: String)

    private struct Fields: Codable {
        var agent: AgentInfo?
        var agentId: UUID?
        var projects: [ProjectInfo]?
        var by: DeviceInfo?
        var activity: String?
        var viewers: [DeviceInfo]?
        var controller: DeviceInfo?
        var tookOverFrom: DeviceInfo?
        var cols: Int?
        var rows: Int?
        var reason: String?
        var message: String?
    }

    package init(from decoder: Decoder) throws {
        let (type, id) = try readTag(decoder)
        func f() throws -> Fields { try Fields(from: decoder) }
        func need<T>(_ v: T?, _ what: String) throws -> T {
            guard let v else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(type) needs \(what)")) }
            return v
        }
        switch type {
        case "welcome": self = .welcome(try Welcome(from: decoder))
        case "pairingRequired": self = .pairingRequired(try PairingRequired(from: decoder))
        case "incompatible": self = .incompatible(try Incompatible(from: decoder))
        case "pairChallenge": self = .pairChallenge(try PairChallenge(from: decoder))
        case "pairWaiting": self = .pairWaiting
        case "paired": self = .paired(try Paired(from: decoder))
        case "reply": self = .reply(id: try need(id, "an id"), try Reply(from: decoder))
        case "error": self = .error(id: id, try ErrorInfo(from: decoder))
        case "agentUpdated": self = .event(.agentUpdated(try need(f().agent, "agent")))
        case "agentRemoved": self = .event(.agentRemoved(try need(f().agentId, "agentId")))
        case "projectsChanged": self = .event(.projectsChanged(try need(f().projects, "projects")))
        case "promptResolved":
            let x = try f()
            self = .event(.promptResolved(agentId: try need(x.agentId, "agentId"), by: try need(x.by, "by"), activity: x.activity ?? ""))
        case "viewers":
            let x = try f()
            self = .event(.viewers(agentId: try need(x.agentId, "agentId"), viewers: x.viewers ?? []))
        case "controller":
            let x = try f()
            self = .event(.controller(agentId: try need(x.agentId, "agentId"), controller: x.controller, tookOverFrom: x.tookOverFrom))
        case "resized":
            let x = try f()
            self = .event(.resized(agentId: try need(x.agentId, "agentId"), cols: try need(x.cols, "cols"), rows: try need(x.rows, "rows")))
        case "inputRefused":
            let x = try f()
            self = .event(.inputRefused(agentId: try need(x.agentId, "agentId"), controller: try need(x.controller, "controller")))
        case "detached":
            let x = try f()
            self = .event(.detached(agentId: try need(x.agentId, "agentId"), reason: x.reason ?? ""))
        case "deviceRevoked": self = .event(.deviceRevoked)
        case "hostStopping":
            let x = try f()
            self = .event(.hostStopping(reason: x.reason ?? "stopped", message: x.message ?? ""))
        default: self = .unknown(type: type)
        }
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .welcome(let m): try writeTag(encoder, "welcome"); try m.encode(to: encoder)
        case .pairingRequired(let m): try writeTag(encoder, "pairingRequired"); try m.encode(to: encoder)
        case .incompatible(let m): try writeTag(encoder, "incompatible"); try m.encode(to: encoder)
        case .pairChallenge(let m): try writeTag(encoder, "pairChallenge"); try m.encode(to: encoder)
        case .pairWaiting: try writeTag(encoder, "pairWaiting")
        case .paired(let m): try writeTag(encoder, "paired"); try m.encode(to: encoder)
        case .reply(let id, let m): try writeTag(encoder, "reply", id: id); try m.encode(to: encoder)
        case .error(let id, let m): try writeTag(encoder, "error", id: id); try m.encode(to: encoder)
        case .unknown(let type): try writeTag(encoder, type)
        case .event(let e):
            var x = Fields()
            let type: String
            switch e {
            case .agentUpdated(let a): type = "agentUpdated"; x.agent = a
            case .agentRemoved(let id): type = "agentRemoved"; x.agentId = id
            case .projectsChanged(let p): type = "projectsChanged"; x.projects = p
            case .promptResolved(let id, let by, let activity): type = "promptResolved"; x.agentId = id; x.by = by; x.activity = activity
            case .viewers(let id, let v): type = "viewers"; x.agentId = id; x.viewers = v
            case .controller(let id, let c, let from): type = "controller"; x.agentId = id; x.controller = c; x.tookOverFrom = from
            case .resized(let id, let cols, let rows): type = "resized"; x.agentId = id; x.cols = cols; x.rows = rows
            case .inputRefused(let id, let c): type = "inputRefused"; x.agentId = id; x.controller = c
            case .detached(let id, let reason): type = "detached"; x.agentId = id; x.reason = reason
            case .deviceRevoked: type = "deviceRevoked"
            case .hostStopping(let reason, let message): type = "hostStopping"; x.reason = reason; x.message = message
            }
            try writeTag(encoder, type)
            try x.encode(to: encoder)
        }
    }
}

// MARK: Binary frames

/// A binary WebSocket frame: terminal bytes for one agent (docs/HOST-PROTOCOL.md §1).
package struct TerminalFrame: Equatable, Sendable {
    package enum Kind: UInt8, Sendable {
        case output = 0x01, snapshot = 0x02, input = 0x03
    }
    package var kind: Kind
    package var agentID: UUID
    package var bytes: [UInt8]

    package init(_ kind: Kind, _ agentID: UUID, _ bytes: [UInt8]) {
        self.kind = kind
        self.agentID = agentID
        self.bytes = bytes
    }

    package var encoded: [UInt8] {
        let u = agentID.uuid
        return [kind.rawValue, u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15] + bytes
    }

    package init?(decoding data: [UInt8]) {
        guard data.count >= 17, let kind = Kind(rawValue: data[0]) else { return nil }
        let b = Array(data[1..<17])
        self.kind = kind
        agentID = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        bytes = Array(data[17...])
    }
}

/// JSON with the same settings everywhere: sorted keys (stable for tests and logs), no escaped slashes.
package enum WireJSON {
    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
