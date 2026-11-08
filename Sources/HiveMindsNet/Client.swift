import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import HiveMindsProtocol

/// Something went wrong talking to a host, in words the app can show.
package enum ClientError: Error, CustomStringConvertible, Equatable {
    case cantConnect(String)
    /// The host presented a different certificate from the one pinned at pairing.
    case identityChanged(expected: String, got: String)
    case refused(String)
    case closed
    case timedOut
    case host(ErrorInfo)
    case pairingFailed(String)

    package var description: String {
        switch self {
        case .cantConnect(let s): "Couldn't connect: \(s)"
        case .identityChanged: "This host's identity changed. It may have been set up again, or something is pretending to be it. Pair again only if you trust it."
        case .refused(let s): "The host refused the connection (\(s))."
        case .closed: "The connection closed."
        case .timedOut: "The host didn't answer in time."
        case .host(let e): e.message
        case .pairingFailed(let s): s
        }
    }

    package static func == (a: ClientError, b: ClientError) -> Bool { a.description == b.description }
}

/// What the host said to `hello`.
package enum HelloResult: Sendable {
    case welcome(Welcome)
    case pairingRequired(PairingRequired)
    case incompatible(Incompatible)
}

/// A connection to a host, for the app (and the tests). Messages that aren't replies arrive through `onMessage`;
/// terminal frames through `onFrame`; both on `queue`.
package final class HostClient: @unchecked Sendable {
    package let identity: Identity
    private let group: MultiThreadedEventLoopGroup
    private let ownsGroup: Bool
    package let queue: DispatchQueue
    private var channel: Channel?
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var waiters: [(id: UUID, match: (HostMessage) -> Bool, cont: CheckedContinuation<HostMessage, Error>)] = []
    private var nextID = 0
    private var isClosed = false
    /// Handshake and pairing messages that came before anything was waiting for them (a reply can beat the
    /// `next` that waits for it, and `welcome` comes right after `paired`). Until the welcome, nothing else is
    /// listening, so everything is kept; after it, only handshake messages are.
    private var unclaimed: [HostMessage] = []
    private var welcomed = false
    /// The fingerprint the host presented in TLS.
    package private(set) var hostFingerprint: String?
    package var onMessage: (HostMessage) -> Void = { _ in }
    package var onFrame: (TerminalFrame) -> Void = { _ in }
    package var onClose: () -> Void = {}

    package init(identity: Identity, group: MultiThreadedEventLoopGroup? = nil, queue: DispatchQueue = DispatchQueue(label: "hiveminds.client")) {
        self.identity = identity
        self.group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        ownsGroup = group == nil
        self.queue = queue
    }

    deinit {
        if ownsGroup { group.shutdownGracefully { _ in } }
    }

    /// Opens the connection: TLS (refusing a host whose certificate isn't `pinned`, when given), then the WebSocket.
    /// `origin` and `hostHeader` exist to test the host's defences.
    package func connect(host: String, port: Int, pinned: String?, timeout: TimeInterval = 10,
                         origin: String? = nil, hostHeader: String = HostProtocol.hostHeader, path: String = HostProtocol.path) async throws {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = [.certificate(try identity.nioCertificate)]
        config.privateKey = .privateKey(try identity.nioKey)
        config.certificateVerification = .noHostnameVerification
        config.minimumTLSVersion = .tlsv13
        let tls = try NIOSSLContext(configuration: config)
        let upgraded = group.next().makePromise(of: Void.self)
        let seen = Seen()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelInitializer { [weak self] ch in
                guard let self else { return ch.close() }
                let ssl: NIOSSLClientHandler
                do {
                    ssl = try NIOSSLClientHandler(context: tls, serverHostname: nil) { certs, promise in
                        guard let leaf = certs.first, let der = try? leaf.toDERBytes() else { return promise.succeed(.failed) }
                        let fp = Identity.fingerprint(of: der)
                        seen.fingerprint = fp
                        promise.succeed(pinned == nil || pinned == fp ? .certificateVerified : .failed)
                    }
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
                let requester = UpgradeRequester(hostHeader: hostHeader, path: path, origin: origin, failed: upgraded)
                let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                let upgrader = NIOWebSocketClientUpgrader(requestKey: key, maxFrameSize: HostProtocol.maxMessageSize) { ch, _ in
                    do {
                        try ch.pipeline.syncOperations.addHandler(ClientFrameHandler(client: self))
                    } catch {
                        return ch.eventLoop.makeFailedFuture(error)
                    }
                    upgraded.succeed(())
                    return ch.eventLoop.makeSucceededVoidFuture()
                }
                do {
                    let pipeline = ch.pipeline.syncOperations
                    try pipeline.addHandler(ssl)
                    try pipeline.addHTTPClientHandlers(withClientUpgrade: (upgraders: [upgrader], completionHandler: { ctx in
                        ctx.pipeline.syncOperations.removeHandler(requester, promise: nil)
                    }))
                    try pipeline.addHandler(requester)
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
        let ch: Channel
        do {
            ch = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw ClientError.cantConnect("\(error)")
        }
        ch.closeFuture.whenComplete { [weak self] _ in
            upgraded.fail(ClientError.closed)
            self?.wentAway()
        }
        do {
            try await upgraded.futureResult.get()
        } catch {
            hostFingerprint = seen.fingerprint
            if let pinned, let got = seen.fingerprint, got != pinned { throw ClientError.identityChanged(expected: pinned, got: got) }
            if let e = error as? ClientError { throw e }
            throw ClientError.cantConnect("\(error)")
        }
        hostFingerprint = seen.fingerprint
        lock.withLock { channel = ch }
    }

    // MARK: Sending

    package func send(_ message: ClientMessage) {
        guard let ch = lock.withLock({ channel }), let data = try? WireJSON.encode(message) else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buf), promise: nil)
    }

    package func send(frame: TerminalFrame) {
        guard let ch = lock.withLock({ channel }) else { return }
        let bytes = frame.encoded
        var buf = ch.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: buf), promise: nil)
    }

    /// Sends a request and waits for its reply. Throws `ClientError.host` with the host's error.
    package func request(_ r: Request, timeout: TimeInterval = 30) async throws -> Reply {
        let id: String = lock.withLock { nextID += 1; return "r\(nextID)" }
        return try await withCheckedThrowingContinuation { cont in
            let closed = lock.withLock { () -> Bool in
                if isClosed { return true }
                pending[id] = cont
                return false
            }
            if closed { return cont.resume(throwing: ClientError.closed) }
            send(.request(id: id, r))
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let c = self?.lock.withLock({ self?.pending.removeValue(forKey: id) }) else { return }
                c.resume(throwing: ClientError.timedOut)
            }
        }
    }

    /// Waits for the next message from the host that `match` accepts (for the handshake and pairing).
    package func next(timeout: TimeInterval = 30, where match: @escaping (HostMessage) -> Bool = { _ in true }) async throws -> HostMessage {
        let token = UUID()
        return try await withCheckedThrowingContinuation { cont in
            enum Now { case wait, closed, got(HostMessage) }
            let now = lock.withLock { () -> Now in
                if let i = unclaimed.firstIndex(where: match) { return .got(unclaimed.remove(at: i)) }
                if isClosed { return .closed }
                waiters.append((token, match, cont))
                return .wait
            }
            switch now {
            case .wait: break
            case .closed: return cont.resume(throwing: ClientError.closed)
            case .got(let m): return cont.resume(returning: m)
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let w = self.lock.withLock { () -> CheckedContinuation<HostMessage, Error>? in
                    guard let i = self.waiters.firstIndex(where: { $0.id == token }) else { return nil }
                    return self.waiters.remove(at: i).cont
                }
                w?.resume(throwing: ClientError.timedOut)
            }
        }
    }

    package func close() {
        guard let ch = lock.withLock({ channel }) else { return }
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: ch.allocator.buffer(capacity: 0))
        ch.writeAndFlush(frame).whenComplete { _ in ch.close(promise: nil) }
    }

    // MARK: Handshake and pairing

    /// Says hello. With a valid token for this device, the result is `welcome`.
    package func hello(client: String, deviceName: String, token: String?) async throws -> HelloResult {
        send(.hello(Hello(client: client, deviceName: deviceName, token: token)))
        let reply = try await next { m in
            switch m {
            case .welcome, .pairingRequired, .incompatible, .error: true
            default: false
            }
        }
        switch reply {
        case .welcome(let w): return .welcome(w)
        case .pairingRequired(let p): return .pairingRequired(p)
        case .incompatible(let i): return .incompatible(i)
        case .error(_, let e): throw ClientError.host(e)
        default: throw ClientError.closed
        }
    }

    /// Pairs with the code shown on the host (after `pairingRequired`). Returns the token and the welcome once the
    /// host's owner has said yes and the host has proved it knew the code. Throws `ClientError.host` with
    /// `wrongCode` (and `triesLeft`), `noCode`, `tooManyTries`, `busy` or `notAllowed`.
    package func pair(code: String, deviceName: String, ownerTimeout: TimeInterval = 90,
                      onWaiting: @escaping @Sendable () -> Void = {}) async throws -> (token: String, welcome: Welcome) {
        guard let hostFP = hostFingerprint else { throw ClientError.closed }
        let exchange = PairingExchange(role: .client, clientFingerprint: identity.fingerprint, hostFingerprint: hostFP, code: code)
        send(.pairStart(PairStart(spake: Data(exchange.message).base64EncodedString(), deviceName: deviceName)))
        let challenge = try await next { m in
            if case .pairChallenge = m { return true }
            if case .error = m { return true }
            return false
        }
        if case .error(_, let e) = challenge { throw ClientError.host(e) }
        guard case .pairChallenge(let c) = challenge, let theirs = Data(base64Encoded: c.spake), exchange.receive(Array(theirs)) else {
            throw ClientError.pairingFailed("The host's pairing answer didn't make sense.")
        }
        send(.pairConfirm(PairConfirm(proof: Data(exchange.myProof).base64EncodedString())))
        var paired: Paired?
        while true {
            let m = try await next(timeout: ownerTimeout) { m in
                switch m {
                case .pairWaiting, .paired, .welcome, .error: true
                default: false
                }
            }
            switch m {
            case .pairWaiting:
                onWaiting()
                continue
            case .error(_, let e): throw ClientError.host(e)
            case .paired(let p):
                guard let proof = Data(base64Encoded: p.hostProof), exchange.checks(Array(proof)) else {
                    close()
                    throw ClientError.pairingFailed("The host couldn't prove it knew the code, so this isn't the host you meant. Nothing was saved.")
                }
                paired = p
            case .welcome(let w):
                guard let paired else { throw ClientError.pairingFailed("The host skipped a step of pairing.") }
                return (paired.token, w)
            default: continue
            }
        }
    }

    // MARK: Receiving

    fileprivate func received(_ message: HostMessage) {
        queue.async {
            if case .reply(let id, let r) = message, let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) {
                return c.resume(returning: r)
            }
            if case .error(let id?, let e) = message, let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) {
                return c.resume(throwing: ClientError.host(e))
            }
            enum Next { case waiter(CheckedContinuation<HostMessage, Error>), kept, listener }
            let next = self.lock.withLock { () -> Next in
                let handshake: Bool = switch message {
                case .welcome, .pairingRequired, .incompatible, .pairChallenge, .pairWaiting, .paired: true
                default: false
                }
                defer { if case .welcome = message { self.welcomed = true } }
                if let i = self.waiters.firstIndex(where: { $0.match(message) }) { return .waiter(self.waiters.remove(at: i).cont) }
                if handshake || !self.welcomed {
                    if self.unclaimed.count < 32 { self.unclaimed.append(message) }
                    return .kept
                }
                return .listener
            }
            switch next {
            case .waiter(let w): w.resume(returning: message)
            case .kept: break
            case .listener: self.onMessage(message)
            }
        }
    }

    fileprivate func received(_ frame: TerminalFrame) {
        queue.async { self.onFrame(frame) }
    }

    fileprivate func wentAway() {
        queue.async {
            let (p, w) = self.lock.withLock { () -> ([CheckedContinuation<Reply, Error>], [CheckedContinuation<HostMessage, Error>]) in
                self.isClosed = true
                let p = Array(self.pending.values), w = self.waiters.map(\.cont)
                self.pending = [:]
                self.waiters = []
                self.channel = nil
                return (p, w)
            }
            for c in p { c.resume(throwing: ClientError.closed) }
            for c in w { c.resume(throwing: ClientError.closed) }
            self.onClose()
        }
    }
}

private final class Seen: @unchecked Sendable {
    var fingerprint: String?
}

private final class ClientFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    weak var client: HostClient?
    private var partial: ByteBuffer?
    private var partialIsText = false

    init(client: HostClient) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary, .continuation:
            var data = frame.unmaskedData
            if frame.opcode != .continuation {
                partial = data
                partialIsText = frame.opcode == .text
            } else {
                partial?.writeBuffer(&data)
            }
            guard frame.fin, let whole = partial else { return }
            partial = nil
            let bytes = whole.getBytes(at: whole.readerIndex, length: whole.readableBytes) ?? []
            if partialIsText {
                if let m = try? WireJSON.decode(HostMessage.self, from: Data(bytes)) { client?.received(m) }
            } else if let f = TerminalFrame(decoding: bytes) {
                client?.received(f)
            }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Sends the upgrade request once connected, and turns a refusal into an error.
private final class UpgradeRequester: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let hostHeader: String, path: String, origin: String?
    let failed: EventLoopPromise<Void>

    init(hostHeader: String, path: String, origin: String?, failed: EventLoopPromise<Void>) {
        self.hostHeader = hostHeader
        self.path = path
        self.origin = origin
        self.failed = failed
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: hostHeader)
        headers.add(name: "Content-Length", value: "0")
        if let origin { headers.add(name: "Origin", value: origin) }
        context.write(wrapOutboundOut(.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            failed.fail(ClientError.refused("HTTP \(head.status.code)"))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failed.fail(ClientError.cantConnect("\(error)"))
        context.close(promise: nil)
    }
}
