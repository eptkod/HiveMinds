import Foundation
import HiveMindsProtocol

/// A value only ever touched on one queue, captured by closures that run later on that same queue.
package final class QueueBox<T>: @unchecked Sendable {
    package var value: T
    package init(_ value: T) { self.value = value }
}

/// Something worth writing in the host's audit log, from the gate.
package enum GateEvent: Sendable {
    case refused(address: String, reason: String)
    case connected(address: String)
    case tokenRejected(address: String, deviceName: String)
    case incompatible(address: String, theirs: Int)
    case pairingStarted(address: String, deviceName: String)
    case wrongCode(address: String, deviceName: String, triesLeft: Int)
    case paired(PairedDevice, address: String)
    case pairingNotAllowed(address: String, deviceName: String)
    case authenticated(PairedDevice, address: String)
    case closed(device: PairedDevice?, address: String)
}

/// An authenticated connection: a paired device, after `welcome`.
package final class Session: @unchecked Sendable {
    package let peer: PeerConnection
    package let device: PairedDevice
    package var onRequest: (String, Request) -> Void = { _, _ in }
    package var onFrame: (TerminalFrame) -> Void = { _ in }
    package var onClose: () -> Void = {}

    init(peer: PeerConnection, device: PairedDevice) {
        self.peer = peer
        self.device = device
    }

    package func send(_ m: HostMessage) { peer.send(m) }
    package func send(frame: TerminalFrame) { peer.send(frame: frame) }
    package func reply(_ id: String, _ r: Reply = Reply()) { peer.send(.reply(id: id, r)) }
    package func fail(_ id: String?, _ e: ErrorInfo) { peer.send(.error(id: id, e)) }
    package func close() { peer.close() }
}

/// Lets connections in (docs/HOST-PROTOCOL.md §2.2–2.3, §3): `hello`, pairing with the owner's yes, then hands
/// each authenticated connection over as a `Session`. Runs on the server's queue.
package final class HostGate {
    package let registry: DeviceRegistry
    package let desk: PairingDesk
    package let hostID: String
    package var hostName: String
    package let hostVersion: String
    package var maxUnauthenticated = 8
    package var helloTimeout = HostProtocol.helloTimeout
    package var pairingTimeout = HostProtocol.pairingTimeout
    /// How long the owner has to answer.
    package var ownerTimeout: TimeInterval = 60

    /// Asks the owner whether this device may use the host; call `answer` once with their choice.
    package var askOwner: (_ name: String, _ fingerprint: String, _ answer: @escaping (Bool) -> Void) -> Void = { _, _, a in a(false) }
    /// The owner didn't answer in time: take the question back.
    package var ownerTimedOut: () -> Void = {}
    package var onSession: (Session) -> Void = { $0.close() }
    package var onEvent: (GateEvent) -> Void = { _ in }
    /// Whether the host is shutting down (new connections are turned away).
    package var closing = false

    private let queue: DispatchQueue
    private var unauthenticated: [UUID: PeerConnection] = [:]
    private var sessions: [UUID: Session] = [:]

    package init(server: HostServer, registry: DeviceRegistry, desk: PairingDesk, hostID: String, hostName: String,
                 hostVersion: String, queue: DispatchQueue) {
        self.registry = registry
        self.desk = desk
        self.hostID = hostID
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.queue = queue
        server.onConnection = { [weak self] peer in self?.arrived(peer) }
        server.onRefusal = { [weak self] address, why in self?.onEvent(.refused(address: address, reason: why.rawValue)) }
    }

    /// The authenticated connections.
    package var allSessions: [Session] { Array(sessions.values) }

    private func arrived(_ peer: PeerConnection) {
        guard !closing, unauthenticated.count < maxUnauthenticated else {
            onEvent(.refused(address: peer.remoteAddress, reason: closing ? "the host is stopping" : "too many connections that haven't signed in"))
            return peer.close()
        }
        unauthenticated[peer.id] = peer
        onEvent(.connected(address: peer.remoteAddress))
        let saidHello = QueueBox(false)
        var name = ""
        queue.asyncAfter(deadline: .now() + helloTimeout) { [weak self] in
            guard let self, !saidHello.value, self.unauthenticated[peer.id] != nil else { return }
            self.drop(peer, ErrorInfo("timedOut", "Say hello first."))
        }
        queue.asyncAfter(deadline: .now() + pairingTimeout) { [weak self] in
            guard let self, self.unauthenticated[peer.id] != nil, self.desk.waiting != peer.id else { return }
            self.drop(peer, ErrorInfo("timedOut", "Pairing took too long. Try again."))
        }
        peer.start(onMessage: { [weak self] m in
            guard let self, self.unauthenticated[peer.id] != nil else { return }
            switch m {
            case .hello(let h):
                guard !saidHello.value else { return self.drop(peer, ErrorInfo("badRequest", "Say hello once.")) }
                saidHello.value = true
                name = String(h.device.name.prefix(80))
                self.hello(peer, h)
            case .pairStart(let p):
                guard saidHello.value else { return self.drop(peer, ErrorInfo("notAuthenticated", "Say hello first.")) }
                name = String(p.device.name.prefix(80))
                guard let spake = Data(base64Encoded: p.spake) else {
                    return peer.send(.error(id: nil, ErrorInfo("badRequest", "That pairing message didn't make sense.")))
                }
                self.onEvent(.pairingStarted(address: peer.remoteAddress, deviceName: name))
                switch self.desk.start(peer.id, deviceName: name, clientFingerprint: peer.clientFingerprint, spake: Array(spake)) {
                case .success(let mine): peer.send(.pairChallenge(PairChallenge(spake: Data(mine).base64EncodedString())))
                case .failure(let e): peer.send(.error(id: nil, e))
                }
            case .pairConfirm(let c):
                guard let proof = Data(base64Encoded: c.proof) else {
                    return peer.send(.error(id: nil, ErrorInfo("badRequest", "That pairing message didn't make sense.")))
                }
                switch self.desk.confirm(peer.id, proof: Array(proof)) {
                case .refused(let e):
                    if e.code == "wrongCode" || e.code == "tooManyTries" {
                        self.onEvent(.wrongCode(address: peer.remoteAddress, deviceName: name, triesLeft: e.triesLeft ?? 0))
                    }
                    peer.send(.error(id: nil, e))
                case .askOwner(let n, let fp):
                    peer.send(.pairWaiting)
                    self.waitForOwner(peer, name: n, fingerprint: fp)
                }
            case .request(let id, _), .unknown(_, let id?):
                self.drop(peer, ErrorInfo("notAuthenticated", "Pair with this host first."), id: id)
            case .unknown:
                self.drop(peer, ErrorInfo("notAuthenticated", "Pair with this host first."))
            }
        }, onFrame: { [weak self] _ in
            self?.drop(peer, ErrorInfo("notAuthenticated", "Pair with this host first."))
        }, onMalformed: { [weak self] in
            self?.drop(peer, ErrorInfo("badRequest", "That message didn't make sense."))
        }, onClose: { [weak self] in
            guard let self, self.unauthenticated.removeValue(forKey: peer.id) != nil else { return }
            if self.desk.waiting == peer.id { self.ownerTimedOut() }
            self.desk.forget(peer.id)
            self.onEvent(.closed(device: nil, address: peer.remoteAddress))
        })
    }

    private func drop(_ peer: PeerConnection, _ e: ErrorInfo, id: String? = nil) {
        peer.send(.error(id: id, e))
        unauthenticated[peer.id] = nil
        desk.forget(peer.id)
        peer.close()
    }

    private func hello(_ peer: PeerConnection, _ h: Hello) {
        guard h.protocol == HostProtocol.version else {
            onEvent(.incompatible(address: peer.remoteAddress, theirs: h.protocol))
            let hostIsOlder = h.protocol > HostProtocol.version
            peer.send(.incompatible(Incompatible(update: hostIsOlder ? "host" : "app",
                                                 message: hostIsOlder ? "This host needs updating to work with this version of HiveMinds."
                                                                      : "Update HiveMinds to use this host.")))
            unauthenticated[peer.id] = nil
            return peer.close()
        }
        guard let token = h.token, !token.isEmpty else {
            return peer.send(.pairingRequired(PairingRequired(hostId: hostID, reason: "noToken")))
        }
        guard let device = registry.authenticate(token: token, fingerprint: peer.clientFingerprint) else {
            onEvent(.tokenRejected(address: peer.remoteAddress, deviceName: String(h.device.name.prefix(80))))
            return peer.send(.pairingRequired(PairingRequired(hostId: hostID, reason: "unknownToken")))
        }
        admit(peer, device)
    }

    private func waitForOwner(_ peer: PeerConnection, name: String, fingerprint: String) {
        let answered = QueueBox(false)
        let finish: (Bool) -> Void = { [weak self] allowed in
            guard let self, !answered.value else { return }
            answered.value = true
            guard self.unauthenticated[peer.id] != nil else { _ = self.desk.ownerAnswered(peer.id, allowed: false); return }
            guard let hostProof = self.desk.ownerAnswered(peer.id, allowed: allowed) else {
                self.onEvent(.pairingNotAllowed(address: peer.remoteAddress, deviceName: name))
                return self.drop(peer, ErrorInfo("notAllowed", "The host's owner didn't allow this device."))
            }
            let (device, token) = self.registry.add(name: name, fingerprint: fingerprint)
            self.onEvent(.paired(device, address: peer.remoteAddress))
            peer.send(.paired(Paired(token: token, hostProof: Data(hostProof).base64EncodedString(), device: device.info)))
            self.admit(peer, device)
        }
        askOwner(name, fingerprint) { allowed in self.queue.async { finish(allowed) } }
        queue.asyncAfter(deadline: .now() + ownerTimeout) { [weak self] in
            guard !answered.value else { return }
            self?.ownerTimedOut()
            finish(false)
        }
    }

    private func admit(_ peer: PeerConnection, _ device: PairedDevice) {
        unauthenticated[peer.id] = nil
        let session = Session(peer: peer, device: device)
        sessions[peer.id] = session
        onEvent(.authenticated(device, address: peer.remoteAddress))
        peer.send(.welcome(Welcome(hostId: hostID, hostName: hostName, hostVersion: hostVersion, device: device.info)))
        peer.start(onMessage: { [weak session] m in
            guard let session else { return }
            switch m {
            case .request(let id, let r): session.onRequest(id, r)
            case .unknown(let type, let id): session.fail(id, ErrorInfo("unknownRequest", "This host doesn't know \"\(type)\". It may need updating."))
            case .hello, .pairStart, .pairConfirm: session.fail(nil, ErrorInfo("badRequest", "Already signed in."))
            }
        }, onFrame: { [weak session] f in
            session?.onFrame(f)
        }, onMalformed: { [weak session] in
            session?.fail(nil, ErrorInfo("badRequest", "That message didn't make sense."))
        }, onClose: { [weak self, weak session] in
            guard let self else { return }
            self.sessions[peer.id] = nil
            self.onEvent(.closed(device: device, address: peer.remoteAddress))
            session?.onClose()
        })
        onSession(session)
    }

    /// Closes the connections of devices that were revoked (by id).
    package func disconnect(deviceIDs: Set<String>) {
        for s in sessions.values where deviceIDs.contains(s.device.id) {
            s.send(.event(.deviceRevoked))
            s.close()
        }
    }
}
