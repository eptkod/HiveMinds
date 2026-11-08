import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import HiveMindsProtocol

/// Why a connection was turned away before it could say anything, for the audit log.
package enum Refusal: String, Sendable {
    case notPrivate = "address isn't on the local network"
    case originHeader = "had an Origin header (a web page)"
    case cookieHeader = "had a Cookie header"
    case wrongHost = "wrong Host header"
    case wrongPath = "wrong path"
    case noClientCertificate = "no client certificate"
    case tooMany = "too many connections"
}

/// One client, once its WebSocket is open. Everything it reports arrives on the server's `queue`; the methods
/// may be called from anywhere.
package final class PeerConnection: @unchecked Sendable {
    package let id = UUID()
    /// The peer's address, as text.
    package let remoteAddress: String
    /// The fingerprint of the client certificate it presented in TLS.
    package let clientFingerprint: String
    private let channel: Channel
    private let queue: DispatchQueue
    private var handlers: (message: (ClientMessage) -> Void, frame: (TerminalFrame) -> Void, closed: () -> Void)?
    private var buffered: [Either] = []
    private var closedSeen = false
    private let lock = NSLock()

    fileprivate enum Either { case message(ClientMessage), frame(TerminalFrame), malformed }

    fileprivate init(channel: Channel, remoteAddress: String, clientFingerprint: String, queue: DispatchQueue) {
        self.channel = channel
        self.remoteAddress = remoteAddress
        self.clientFingerprint = clientFingerprint
        self.queue = queue
    }

    /// Starts delivering what the client sends. Messages that arrived before are delivered first.
    package func start(onMessage: @escaping (ClientMessage) -> Void, onFrame: @escaping (TerminalFrame) -> Void,
                       onMalformed: @escaping () -> Void, onClose: @escaping () -> Void) {
        queue.async {
            self.handlers = (onMessage, onFrame, onClose)
            self.malformed = onMalformed
            let early = self.lock.withLock { () -> [Either] in let b = self.buffered; self.buffered = []; return b }
            for e in early { self.deliver(e) }
            if self.lock.withLock({ self.closedSeen }) { onClose(); self.handlers = nil }
        }
    }

    private var malformed: (() -> Void)?

    private func deliver(_ e: Either) {
        switch e {
        case .message(let m): handlers?.message(m)
        case .frame(let f): handlers?.frame(f)
        case .malformed: malformed?()
        }
    }

    fileprivate func received(_ e: Either) {
        queue.async {
            if self.handlers == nil { self.lock.withLock { self.buffered.append(e) } } else { self.deliver(e) }
        }
    }

    fileprivate func receivedText(_ data: Data) {
        if let m = try? WireJSON.decode(ClientMessage.self, from: data) { received(.message(m)) } else { received(.malformed) }
    }

    fileprivate func receivedBinary(_ bytes: [UInt8]) {
        if let f = TerminalFrame(decoding: bytes) { received(.frame(f)) } else { received(.malformed) }
    }

    fileprivate func wentAway() {
        queue.async {
            self.lock.withLock { self.closedSeen = true }
            if let h = self.handlers { self.handlers = nil; h.closed() }
        }
    }

    package func send(_ message: HostMessage) {
        guard let data = try? WireJSON.encode(message) else { return }
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buf), promise: nil)
    }

    package func send(frame: TerminalFrame) {
        let bytes = frame.encoded
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buf), promise: nil)
    }

    /// Closes the connection (after anything already sent).
    package func close() {
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: channel.allocator.buffer(capacity: 0))
        channel.writeAndFlush(frame).whenComplete { [channel] _ in channel.close(promise: nil) }
    }
}

/// Reassembles messages, answers pings, and hands text and binary messages to the connection.
private final class ServerFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let peer: PeerConnection
    private var partial: ByteBuffer?
    private var partialIsText = false

    init(peer: PeerConnection) { self.peer = peer }

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
            guard let whole = partial else { return }
            if whole.readableBytes > HostProtocol.maxMessageSize { return context.close(promise: nil) }
            guard frame.fin else { return }
            partial = nil
            let bytes = whole.getBytes(at: whole.readerIndex, length: whole.readableBytes) ?? []
            if partialIsText { peer.receivedText(Data(bytes)) } else { peer.receivedBinary(bytes) }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) { peer.wentAway() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Answers every plain HTTP request (not an upgrade, or one we refused) with an error, then closes.
private final class RefuseHTTP: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    var status: HTTPResponseStatus = .forbidden

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

/// The host's listener: TLS, then a WebSocket at `HostProtocol.path`, on the addresses it's told to use.
package final class HostServer: @unchecked Sendable {
    package let identity: Identity
    private let group: MultiThreadedEventLoopGroup
    private let queue: DispatchQueue
    private let tls: NIOSSLContext
    private var listeners: [String: Channel] = [:]
    private let lock = NSLock()
    private var open = 0
    /// Whether a peer address is allowed (default: private only).
    package var allowsPeer: (String) -> Bool = PrivateAddress.isPrivate
    package var maxConnections = 64
    /// A new client, with its WebSocket open. Called on `queue`.
    package var onConnection: (PeerConnection) -> Void = { $0.close() }
    /// A connection turned away before its WebSocket opened. Called on `queue`.
    package var onRefusal: (String, Refusal) -> Void = { _, _ in }

    package init(identity: Identity, queue: DispatchQueue, threads: Int = 2) throws {
        self.identity = identity
        self.queue = queue
        group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(try identity.nioCertificate)],
                                                              privateKey: .privateKey(try identity.nioKey))
        // Ask for (and require) a client certificate; who it belongs to is decided by pairing and tokens.
        config.certificateVerification = .noHostnameVerification
        config.minimumTLSVersion = .tlsv13
        tls = try NIOSSLContext(configuration: config)
    }

    /// The addresses it's listening on.
    package var addresses: [String] { lock.withLock { Array(listeners.keys).sorted() } }

    /// Starts listening on `address` (a numeric IPv4 or IPv6 address, link-local with "%interface"). Returns the
    /// port actually used (useful with port 0).
    @discardableResult
    package func listen(on address: String, port: Int) throws -> Int {
        if let existing = lock.withLock({ listeners[address] }) { return existing.localAddress?.port ?? port }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { [weak self] ch in
                guard let self else { return ch.close() }
                return self.setUp(ch)
            }
        let channel = try bootstrap.bind(to: try SocketAddress.makeAddressResolvingHost(address, port: port)).wait()
        lock.withLock { listeners[address] = channel }
        return channel.localAddress?.port ?? port
    }

    /// Stops listening on `address`. Open connections stay.
    package func stopListening(on address: String) {
        guard let ch = lock.withLock({ listeners.removeValue(forKey: address) }) else { return }
        ch.close(promise: nil)
    }

    package func shutDown() {
        let all = lock.withLock { () -> [Channel] in let l = Array(listeners.values); listeners = [:]; return l }
        for ch in all { try? ch.close().wait() }
        try? group.syncShutdownGracefully()
    }

    private func refuse(_ ch: Channel, _ address: String, _ why: Refusal) -> EventLoopFuture<Void> {
        queue.async { self.onRefusal(address, why) }
        return ch.close()
    }

    private func setUp(_ ch: Channel) -> EventLoopFuture<Void> {
        let address = ch.remoteAddress?.ipAddress ?? "?"
        guard allowsPeer(address) else { return refuse(ch, address, .notPrivate) }
        let count = lock.withLock { () -> Int in open += 1; return open }
        ch.closeFuture.whenComplete { [weak self] _ in self?.lock.withLock { self?.open -= 1 } }
        guard count <= maxConnections else { return refuse(ch, address, .tooMany) }

        let fingerprint = FingerprintBox()
        let ssl = NIOSSLServerHandler(context: tls) { certs, promise in
            // Any certificate is fine at this layer; its fingerprint identifies the device.
            if let leaf = certs.first, let der = try? leaf.toDERBytes() {
                fingerprint.value = Identity.fingerprint(of: der)
                promise.succeed(.certificateVerified)
            } else {
                promise.succeed(.failed)
            }
        }
        let refusing = RefuseHTTP()
        let queue = self.queue
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: HostProtocol.maxMessageSize, shouldUpgrade: { [weak self] ch, head in
            let why: Refusal?
            if head.headers.contains(name: "Origin") { why = .originHeader }
            else if head.headers.contains(name: "Cookie") { why = .cookieHeader }
            else if head.headers["Host"].first != HostProtocol.hostHeader { why = .wrongHost }
            else if head.uri != HostProtocol.path { why = .wrongPath }
            else if fingerprint.value == nil { why = .noClientCertificate }
            else { why = nil }
            if let why {
                refusing.status = why == .wrongPath ? .notFound : .forbidden
                queue.async { [weak self] in self?.onRefusal(address, why) }
                return ch.eventLoop.makeSucceededFuture(nil)
            }
            return ch.eventLoop.makeSucceededFuture(HTTPHeaders())
        }, upgradePipelineHandler: { [weak self] ch, _ in
            guard let self, let fp = fingerprint.value else { return ch.close() }
            let peer = PeerConnection(channel: ch, remoteAddress: address, clientFingerprint: fp, queue: queue)
            do {
                try ch.pipeline.syncOperations.addHandler(ServerFrameHandler(peer: peer))
            } catch {
                return ch.eventLoop.makeFailedFuture(error)
            }
            queue.async { self.onConnection(peer) }
            return ch.eventLoop.makeSucceededVoidFuture()
        })
        do {
            let pipeline = ch.pipeline.syncOperations
            try pipeline.addHandler(ssl)
            try pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { ctx in
                ctx.pipeline.syncOperations.removeHandler(refusing, promise: nil)
            }))
            try pipeline.addHandler(refusing)
            return ch.eventLoop.makeSucceededVoidFuture()
        } catch {
            return ch.eventLoop.makeFailedFuture(error)
        }
    }
}

private final class FingerprintBox: @unchecked Sendable {
    var value: String?
}
