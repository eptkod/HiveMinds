import Foundation
import Testing
@testable import HiveMindsNet
import HiveMindsProtocol

@Suite struct AddressTests {
    @Test func privateMeansTheLocalNetworkOnly() {
        for a in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.1.20", "169.254.3.4", "127.0.0.1",
                  "::1", "fd12:3456::1", "fc00::1", "fe80::1", "fe80::1%en0", "::ffff:192.168.1.2"] {
            #expect(PrivateAddress.isPrivate(a), "\(a) should be private")
        }
        for a in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.64.0.1", "203.0.113.5", "1.1.1.1",
                  "2001:4860:4860::8888", "::ffff:8.8.8.8", "not an address", "", "fec0::1"] {
            #expect(!PrivateAddress.isPrivate(a), "\(a) should not be private")
        }
    }

    @Test func thisMachineHasAtLeastLoopback() {
        let local = PrivateAddress.local()
        #expect(local.contains { $0.address == "127.0.0.1" })
        #expect(local.allSatisfy { PrivateAddress.isPrivate($0.address) })
    }
}

@Suite struct ProtocolTests {
    func roundTrip(_ m: ClientMessage) throws -> ClientMessage { try WireJSON.decode(ClientMessage.self, from: WireJSON.encode(m)) }
    func roundTrip(_ m: HostMessage) throws -> HostMessage { try WireJSON.decode(HostMessage.self, from: WireJSON.encode(m)) }

    @Test func messagesKeepTheirShape() throws {
        let hello = try WireJSON.encode(ClientMessage.hello(Hello(client: "HiveMinds 1.8.0", deviceName: "Mac", token: nil)))
        let json = try #require(JSONSerialization.jsonObject(with: hello) as? [String: Any])
        #expect(json["type"] as? String == "hello" && json["protocol"] as? Int == 1)
        #expect((json["device"] as? [String: Any])?["name"] as? String == "Mac")

        let id = UUID()
        guard case .request(let rid, .answer(let a)) = try roundTrip(.request(id: "9", .answer(Answer(id, action: "answer", answers: [.option(2), .text("hi")])))) else {
            Issue.record("wrong case"); return
        }
        #expect(rid == "9" && a.agentId == id && a.answers == [.option(2), .text("hi")])
        guard case .unknown(let type, let uid) = try WireJSON.decode(ClientMessage.self, from: Data(#"{"type":"teleport","id":"3"}"#.utf8)) else {
            Issue.record("should be unknown"); return
        }
        #expect(type == "teleport" && uid == "3")

        let agent = AgentInfo(id: id, projectId: UUID(), title: "T", provider: "claude", model: "haiku", createdAt: 1, status: "needsYou",
                              activity: "Has a question", ask: .questions([QuestionInfo(header: "", question: "Q?", options: ["a"], multiSelect: false)]),
                              running: true, cols: 120, rows: 40, controller: DeviceInfo(id: "d1", name: "Mac"))
        guard case .event(.agentUpdated(let back)) = try roundTrip(.event(.agentUpdated(agent))) else { Issue.record("wrong case"); return }
        #expect(back == agent)
        guard case .event(.controller(let aid, let c, let from)) = try roundTrip(.event(.controller(agentId: id, controller: nil, tookOverFrom: DeviceInfo(id: "x", name: "Alex")))) else {
            Issue.record("wrong case"); return
        }
        #expect(aid == id && c == nil && from?.name == "Alex")
        guard case .error(let eid, let e) = try roundTrip(.error(id: "4", ErrorInfo("wrongCode", "No.", triesLeft: 2))) else { Issue.record("wrong case"); return }
        #expect(eid == "4" && e.code == "wrongCode" && e.triesLeft == 2)
    }

    @Test func terminalFramesCarryTheAgentAndBytes() {
        let f = TerminalFrame(.output, UUID(), Array("hello\u{1b}[0m".utf8))
        #expect(TerminalFrame(decoding: f.encoded) == f)
        #expect(f.encoded.count == 17 + 9)
        #expect(TerminalFrame(decoding: [0x09] + Array(repeating: 0, count: 16)) == nil)
        #expect(TerminalFrame(decoding: [0x01, 2, 3]) == nil)
    }
}

@Suite struct RegistryTests {
    @Test func tokensAreHashedAndBoundToTheCertificate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-reg-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("devices.json")
        let r = try DeviceRegistry(file: file)
        let (d, token) = r.add(name: "Ethan's Mac", fingerprint: "AAAA")
        #expect(token.count == 43)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains(token) && saved.contains(DeviceToken.hash(token)))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(r.authenticate(token: token, fingerprint: "AAAA")?.id == d.id)
        #expect(r.authenticate(token: token, fingerprint: "BBBB") == nil)
        #expect(r.authenticate(token: "wrong", fingerprint: "AAAA") == nil)
        // Ninety days unused and it's gone.
        #expect(r.authenticate(token: token, fingerprint: "AAAA", now: Date().addingTimeInterval(91 * 86400)) == nil)
        #expect(r.devices.isEmpty)
        let (_, t2) = r.add(name: "Phone", fingerprint: "CCCC")
        #expect(r.revoke("Phone").count == 1)
        #expect(r.authenticate(token: t2, fingerprint: "CCCC") == nil)
        // Another process's change is picked up.
        _ = r.add(name: "Again", fingerprint: "DDDD")
        let other = try DeviceRegistry(file: file)
        #expect(other.devices.map(\.name) == ["Again"])
    }

    @Test func pairingCodesAreSixDigitsShortLivedAndLimited() {
        var c = PairingCode()
        #expect(c.digits.count == 6 && c.digits.allSatisfy(\.isNumber))
        #expect(c.display.count == 7)
        #expect(c.isUsable() && !c.isUsable(at: Date().addingTimeInterval(61)))
        c.failedTry(); c.failedTry()
        #expect(c.isUsable())
        c.failedTry()
        #expect(!c.isUsable())
        var d = PairingCode()
        d.use()
        #expect(!d.isUsable())
    }
}

/// A host's network side (server + gate) on 127.0.0.1 with a known code and an owner who answers as told.
final class TestHost: @unchecked Sendable {
    let queue = DispatchQueue(label: "test-host")
    let identity: Identity
    let server: HostServer
    let gate: HostGate
    var port = 0
    var ownerSays = true
    var ownerAsked: [(String, String)] = []
    var events: [GateEvent] = []
    var sessions: [Session] = []

    init() throws {
        identity = try Identity(commonName: "test-host")
        server = try HostServer(identity: identity, queue: queue)
        let registry = try DeviceRegistry(file: nil)
        let desk = PairingDesk(hostFingerprint: identity.fingerprint)
        gate = HostGate(server: server, registry: registry, desk: desk, hostID: "0123456789abcdef", hostName: "test-host",
                        hostVersion: "0.3.0", queue: queue)
        gate.askOwner = { [weak self] name, fp, answer in
            guard let self else { return answer(false) }
            self.ownerAsked.append((name, fp))
            answer(self.ownerSays)
        }
        gate.onEvent = { [weak self] e in self?.events.append(e) }
        gate.onSession = { [weak self] s in
            self?.sessions.append(s)
            s.onRequest = { id, r in
                if case .listProjects = r { s.reply(id, { var x = Reply(); x.projects = []; return x }()) }
                else { s.fail(id, ErrorInfo("unknownRequest", "test host")) }
            }
        }
        port = try server.listen(on: "127.0.0.1", port: 0)
    }

    func code(_ digits: String) {
        queue.sync { gate.desk.setCode(PairingCode(digits: digits, expires: Date().addingTimeInterval(60))) }
    }

    deinit { server.shutDown() }
}

@Suite(.serialized) struct GateTests {
    func client(_ id: Identity? = nil) throws -> HostClient { HostClient(identity: try id ?? Identity(commonName: "device")) }

    @Test func pairOnceThenSignInWithTheToken() async throws {
        let host = try TestHost()
        host.code("482913")
        let device = try Identity(commonName: "device")
        let c = try client(device)
        try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        #expect(c.hostFingerprint == host.identity.fingerprint)
        guard case .pairingRequired(let p) = try await c.hello(client: "test", deviceName: "Ethan's Mac", token: nil) else {
            Issue.record("expected pairingRequired"); return
        }
        #expect(p.reason == "noToken" && p.hostId == "0123456789abcdef")
        let (token, welcome) = try await c.pair(code: "482913", deviceName: "Ethan's Mac")
        #expect(welcome.hostName == "test-host" && welcome.device.name == "Ethan's Mac")
        #expect(host.queue.sync { host.ownerAsked.first?.0 } == "Ethan's Mac")
        #expect(host.queue.sync { host.ownerAsked.first?.1 } == device.fingerprint)
        let reply = try await c.request(.listProjects)
        #expect(reply.projects == [])
        c.close()

        // Next time: the pinned host, the token, straight in.
        let again = try client(device)
        try await again.connect(host: "127.0.0.1", port: host.port, pinned: host.identity.fingerprint)
        guard case .welcome(let w) = try await again.hello(client: "test", deviceName: "Ethan's Mac", token: token) else {
            Issue.record("expected welcome"); return
        }
        #expect(w.device.id == welcome.device.id)
        again.close()

        // The same token from another device (another certificate) doesn't work.
        let thief = try client()
        try await thief.connect(host: "127.0.0.1", port: host.port, pinned: host.identity.fingerprint)
        guard case .pairingRequired(let p2) = try await thief.hello(client: "test", deviceName: "Thief", token: token) else {
            Issue.record("expected pairingRequired"); return
        }
        #expect(p2.reason == "unknownToken")
        thief.close()
    }

    @Test func threeWrongCodesUseItUpAndTheRightOneThenFails() async throws {
        let host = try TestHost()
        host.code("111111")
        let c = try client()
        try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        _ = try await c.hello(client: "test", deviceName: "Guesser", token: nil)
        var codes: [String] = []
        for guess in ["000001", "000002", "000003", "111111"] {
            do {
                _ = try await c.pair(code: guess, deviceName: "Guesser")
                codes.append("paired")
            } catch ClientError.host(let e) {
                codes.append("\(e.code):\(e.triesLeft.map(String.init) ?? "-")")
            }
        }
        #expect(codes == ["wrongCode:2", "wrongCode:1", "tooManyTries:0", "tooManyTries:-"])
        #expect(host.queue.sync { host.ownerAsked.isEmpty })
        // A new code works.
        host.code("222222")
        let (token, _) = try await c.pair(code: "222222", deviceName: "Guesser")
        #expect(!token.isEmpty)
        // And it's single use.
        let other = try client()
        try await other.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        _ = try await other.hello(client: "test", deviceName: "Second", token: nil)
        await #expect(throws: ClientError.self) { _ = try await other.pair(code: "222222", deviceName: "Second") }
    }

    @Test func theOwnerCanSayNo() async throws {
        let host = try TestHost()
        host.ownerSays = false
        host.code("333333")
        let c = try client()
        try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        _ = try await c.hello(client: "test", deviceName: "Stranger", token: nil)
        do {
            _ = try await c.pair(code: "333333", deviceName: "Stranger")
            Issue.record("should not pair")
        } catch ClientError.host(let e) {
            #expect(e.code == "notAllowed")
        }
        #expect(host.queue.sync { host.gate.registry.devices.isEmpty })
    }

    @Test func browsersAndRebindingAreRefused() async throws {
        let host = try TestHost()
        for (origin, hostHeader, path, expected) in [("http://evil.example", HostProtocol.hostHeader, HostProtocol.path, "HTTP 403"),
                                                      (nil, "evil.example", HostProtocol.path, "HTTP 403"),
                                                      (nil, "192.168.1.20:7420", HostProtocol.path, "HTTP 403"),
                                                      (nil, HostProtocol.hostHeader, "/", "HTTP 404")] {
            let c = try client()
            do {
                try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil, origin: origin, hostHeader: hostHeader, path: path)
                Issue.record("should have been refused: \(origin ?? "") \(hostHeader) \(path)")
            } catch ClientError.refused(let why) {
                #expect(why == expected)
            }
        }
        let reasons = host.queue.sync { host.events.compactMap { if case .refused(_, let r) = $0 { r } else { nil } } }
        #expect(reasons == [Refusal.originHeader.rawValue, Refusal.wrongHost.rawValue, Refusal.wrongHost.rawValue, Refusal.wrongPath.rawValue])
    }

    @Test func aHostWithAnotherCertificateIsCaught() async throws {
        let host = try TestHost()
        let c = try client()
        do {
            try await c.connect(host: "127.0.0.1", port: host.port, pinned: String(repeating: "0", count: 64))
            Issue.record("should have refused")
        } catch let e as ClientError {
            #expect(e == .identityChanged(expected: String(repeating: "0", count: 64), got: host.identity.fingerprint))
        }
    }

    @Test func nonPrivatePeersAreClosedAtOnce() async throws {
        let host = try TestHost()
        host.server.allowsPeer = { _ in false }
        let c = try client()
        await #expect(throws: ClientError.self) { try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil) }
        let refused = host.queue.sync { host.events.contains { if case .refused(_, let r) = $0 { r == Refusal.notPrivate.rawValue } else { false } } }
        #expect(refused)
    }

    @Test func nothingWorksBeforeSigningInAndOldAppsAreToldToUpdate() async throws {
        let host = try TestHost()
        let c = try client()
        try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        _ = try await c.hello(client: "test", deviceName: "Sneaky", token: nil)
        do {
            _ = try await c.request(.listAgents)
            Issue.record("should be refused")
        } catch ClientError.host(let e) {
            #expect(e.code == "notAuthenticated")
        }

        let old = try client()
        try await old.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        old.send(.hello(Hello(protocol: 0, client: "HiveMinds 1.0", deviceName: "Old", token: nil)))
        guard case .incompatible(let i) = try await old.next() else { Issue.record("expected incompatible"); return }
        #expect(i.update == "app")
        let newer = try client()
        try await newer.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        newer.send(.hello(Hello(protocol: 2, client: "HiveMinds 9", deviceName: "New", token: nil)))
        guard case .incompatible(let j) = try await newer.next() else { Issue.record("expected incompatible"); return }
        #expect(j.update == "host")
    }

    @Test func aRevokedDeviceIsCutOffAndCantComeBack() async throws {
        let host = try TestHost()
        host.code("444444")
        let device = try Identity(commonName: "device")
        let c = try client(device)
        let revoked = Flag()
        c.onMessage = { m in if case .event(.deviceRevoked) = m { revoked.set() } }
        try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        _ = try await c.hello(client: "test", deviceName: "Lost phone", token: nil)
        let (token, welcome) = try await c.pair(code: "444444", deviceName: "Lost phone")
        host.queue.sync {
            let gone = host.gate.registry.revoke("Lost phone")
            host.gate.disconnect(deviceIDs: Set(gone.map(\.id)))
        }
        for _ in 0..<50 where !revoked.value { try await Task.sleep(for: .milliseconds(50)) }
        #expect(revoked.value)
        #expect(welcome.device.name == "Lost phone")
        let back = try client(device)
        try await back.connect(host: "127.0.0.1", port: host.port, pinned: host.identity.fingerprint)
        guard case .pairingRequired(let p) = try await back.hello(client: "test", deviceName: "Lost phone", token: token) else {
            Issue.record("expected pairingRequired"); return
        }
        #expect(p.reason == "unknownToken")
    }

    @Test func aClientThatNeverSaysHelloIsDropped() async throws {
        let host = try TestHost()
        host.gate.helloTimeout = 0.5
        let c = try client()
        let closed = Flag()
        c.onClose = { closed.set() }
        try await c.connect(host: "127.0.0.1", port: host.port, pinned: nil)
        for _ in 0..<40 where !closed.value { try await Task.sleep(for: .milliseconds(50)) }
        #expect(closed.value)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}
