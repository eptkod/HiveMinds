import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import Crypto
import X509
import SwiftASN1
import CSpake

// MARK: - Identity (self-signed certificate)

struct Identity {
    let key: P256.Signing.PrivateKey
    let der: [UInt8]
    var fingerprint: String { Identity.fingerprint(der) }

    init(commonName: String) throws {
        key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(commonName) }
        let now = Date()
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(3650 * 86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) },
            issuerPrivateKey: .init(key))
        var ser = DER.Serializer()
        try ser.serialize(cert)
        der = ser.serializedBytes
    }

    static func fingerprint(_ der: [UInt8]) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    var nioCert: NIOSSLCertificate { try! NIOSSLCertificate(bytes: der, format: .der) }
    var nioKey: NIOSSLPrivateKey { try! NIOSSLPrivateKey(bytes: Array(key.derRepresentation), format: .der) }
}

// MARK: - SPAKE2 pairing (BoringSSL)

/// One side of a SPAKE2 exchange. The client is Alice, the host is Bob. Names bind the run to both
/// certificate fingerprints as each side saw them in TLS, so a relay in the middle gets a different key.
final class Spake {
    private let ctx: OpaquePointer
    let message: [UInt8]

    init(isClient: Bool, clientFP: String, hostFP: String, code: String) {
        let me = Array((isClient ? "client:" + clientFP : "host:" + hostFP).utf8)
        let them = Array((isClient ? "host:" + hostFP : "client:" + clientFP).utf8)
        ctx = CNIOBoringSSL_SPAKE2_CTX_new(isClient ? spake2_role_alice : spake2_role_bob, me, me.count, them, them.count)
        var out = [UInt8](repeating: 0, count: 32)
        var len = 0
        let pw = Array(code.utf8)
        precondition(CNIOBoringSSL_SPAKE2_generate_msg(ctx, &out, &len, out.count, pw, pw.count) == 1)
        message = Array(out[..<len])
    }

    deinit { CNIOBoringSSL_SPAKE2_CTX_free(ctx) }

    /// The shared key, or nil if the peer's message is malformed. A wrong code gives a different key, not an error.
    func finish(_ theirs: [UInt8]) -> SymmetricKey? {
        var key = [UInt8](repeating: 0, count: 64)
        var len = 0
        guard CNIOBoringSSL_SPAKE2_process_msg(ctx, &key, &len, key.count, theirs, theirs.count) == 1 else { return nil }
        return SymmetricKey(data: key[..<len])
    }

    static func confirmation(_ key: SymmetricKey, role: String, clientFP: String, hostFP: String) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Array("hiveminds-pair-v1|\(role)|\(clientFP)|\(hostFP)".utf8), using: key))
    }
}

// MARK: - Frames

/// Binary WebSocket frame: one type byte, then the payload.
enum Frame: UInt8 {
    case pairStart = 0x10, pairHost = 0x11, pairConfirm = 0x12, pairResult = 0x13
    case attach = 0x20, detach = 0x21, snapshot = 0x22, output = 0x23, input = 0x24
    case sync = 0x30, syncAck = 0x31
    case error = 0x7F
}

func wsFrame(_ type: Frame, _ payload: [UInt8], allocator: ByteBufferAllocator, mask: Bool) -> WebSocketFrame {
    var buf = allocator.buffer(capacity: payload.count + 1)
    buf.writeInteger(type.rawValue)
    buf.writeBytes(payload)
    return WebSocketFrame(fin: true, opcode: .binary, maskKey: mask ? .random() : nil, data: buf)
}

/// Handles control frames and hands binary messages (reassembled) to a callback.
final class WSHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let isClient: Bool
    let onMessage: (Channel, Frame, [UInt8]) -> Void
    let onClose: (Channel) -> Void
    private var partial: ByteBuffer?

    init(isClient: Bool, onMessage: @escaping (Channel, Frame, [UInt8]) -> Void, onClose: @escaping (Channel) -> Void) {
        self.isClient = isClient
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .continuation:
            var data = frame.unmaskedData
            if frame.opcode == .binary { partial = data } else { partial?.writeBuffer(&data) }
            guard frame.fin, var whole = partial else { return }
            partial = nil
            guard let t = whole.readInteger(as: UInt8.self), let type = Frame(rawValue: t) else { return }
            onMessage(context.channel, type, whole.readBytes(length: whole.readableBytes) ?? [])
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: isClient ? .random() : nil, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default: break
        }
    }

    func channelInactive(context: ChannelHandlerContext) { onClose(context.channel) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Answers any plain HTTP request (no upgrade, or an upgrade we refused) with 403 and closes.
final class RefuseHTTP: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .forbidden, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

// MARK: - Server

final class SpikeServer {
    let identity: Identity
    let group: MultiThreadedEventLoopGroup
    var channel: Channel?
    /// The client certificate fingerprint for each connection, captured in TLS verification.
    private var peerFP: [ObjectIdentifier: String] = [:]
    private let lock = NSLock()
    var onMessage: (Channel, String, Frame, [UInt8]) -> Void = { _, _, _, _ in }
    var onClose: (Channel) -> Void = { _ in }
    var log: (String) -> Void = { print("host:", $0) }

    init(identity: Identity, group: MultiThreadedEventLoopGroup) {
        self.identity = identity
        self.group = group
    }

    func clientFP(_ ch: Channel) -> String? { lock.withLock { peerFP[ObjectIdentifier(ch)] } }

    func start(host: String, port: Int) throws {
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(identity.nioCert)], privateKey: .privateKey(identity.nioKey))
        tls.certificateVerification = .noHostnameVerification  // require a client certificate; trust is decided by pairing/tokens
        tls.minimumTLSVersion = .tlsv13
        let ctx = try NIOSSLContext(configuration: tls)
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [unowned self] ch in
                let fpBox = ObjectIdentifier(ch)
                let ssl = NIOSSLServerHandler(context: ctx) { certs, promise in
                    // Any client certificate is accepted at the TLS layer; its fingerprint identifies the device.
                    if let leaf = certs.first, let der = try? leaf.toDERBytes() {
                        self.lock.withLock { self.peerFP[fpBox] = Identity.fingerprint(der) }
                        promise.succeed(.certificateVerified)
                    } else {
                        promise.succeed(.failed)
                    }
                }
                let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 1 << 24, shouldUpgrade: { ch, head in
                    // Browser defences: no Origin header at all, and Host must be our own name.
                    if head.headers.contains(name: "Origin") {
                        self.log("refused a request with an Origin header (\(head.headers["Origin"].first ?? ""))")
                        return ch.eventLoop.makeSucceededFuture(nil)
                    }
                    guard head.headers["Host"].first?.hasPrefix("hiveminds-host") == true else {
                        self.log("refused a request with Host \(head.headers["Host"].first ?? "none")")
                        return ch.eventLoop.makeSucceededFuture(nil)
                    }
                    return ch.eventLoop.makeSucceededFuture(HTTPHeaders())
                }, upgradePipelineHandler: { ch, _ in
                    ch.pipeline.addHandler(WSHandler(isClient: false, onMessage: { c, t, p in
                        self.onMessage(c, self.clientFP(c) ?? "", t, p)
                    }, onClose: { c in
                        self.lock.withLock { _ = self.peerFP.removeValue(forKey: ObjectIdentifier(c)) }
                        self.onClose(c)
                    }))
                })
                let refuse = RefuseHTTP()
                return ch.pipeline.addHandler(ssl).flatMap {
                    ch.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { ctx in
                        ctx.pipeline.removeHandler(refuse, promise: nil)
                    }))
                }.flatMap { ch.pipeline.addHandler(refuse) }
            }
            .bind(host: host, port: port).wait()
    }

    func send(_ ch: Channel, _ type: Frame, _ payload: [UInt8]) {
        ch.writeAndFlush(wsFrame(type, payload, allocator: ch.allocator, mask: false), promise: nil)
    }
}

// MARK: - Client

final class SpikeClient {
    enum Failure: Error { case refused(String) }
    let identity: Identity
    let group: MultiThreadedEventLoopGroup
    /// The host fingerprint seen during the TLS handshake.
    private(set) var hostFP: String?
    var channel: Channel?

    init(identity: Identity, group: MultiThreadedEventLoopGroup) {
        self.identity = identity
        self.group = group
    }

    /// Connects. With `pinned`, refuses a host whose certificate doesn't match it.
    func connect(host: String, port: Int, pinned: String?, origin: String? = nil, hostHeader: String = "hiveminds-host",
                 onMessage: @escaping (Frame, [UInt8]) -> Void, onClose: @escaping () -> Void = {}) throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateChain = [.certificate(identity.nioCert)]
        tls.privateKey = .privateKey(identity.nioKey)
        tls.certificateVerification = .noHostnameVerification
        tls.minimumTLSVersion = .tlsv13
        let ctx = try NIOSSLContext(configuration: tls)
        let upgraded = group.next().makePromise(of: Void.self)
        let ch = try ClientBootstrap(group: group).channelInitializer { [unowned self] ch in
            let ssl = try! NIOSSLClientHandler(context: ctx, serverHostname: nil) { certs, promise in
                guard let leaf = certs.first, let der = try? leaf.toDERBytes() else { return promise.succeed(.failed) }
                let fp = Identity.fingerprint(der)
                self.hostFP = fp
                promise.succeed(pinned == nil || pinned == fp ? .certificateVerified : .failed)
            }
            let request = UpgradeRequester(host: hostHeader, origin: origin, failed: upgraded)
            let upgrader = NIOWebSocketClientUpgrader(requestKey: Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
                                                      maxFrameSize: 1 << 24, upgradePipelineHandler: { ch, _ in
                ch.pipeline.addHandler(WSHandler(isClient: true, onMessage: { _, t, p in onMessage(t, p) }, onClose: { _ in onClose() }))
                    .map { upgraded.succeed(()) }
            })
            return ch.pipeline.addHandler(ssl).flatMap {
                ch.pipeline.addHTTPClientHandlers(withClientUpgrade: (upgraders: [upgrader], completionHandler: { ctx in
                    ctx.pipeline.removeHandler(request, promise: nil)
                }))
            }.flatMap { ch.pipeline.addHandler(request) }
        }.connect(host: host, port: port).wait()
        ch.closeFuture.whenComplete { _ in upgraded.fail(Failure.refused("connection closed")) }
        try upgraded.futureResult.wait()
        channel = ch
    }

    func send(_ type: Frame, _ payload: [UInt8]) {
        guard let ch = channel else { return }
        ch.writeAndFlush(wsFrame(type, payload, allocator: ch.allocator, mask: true), promise: nil)
    }

    func close() { try? channel?.close().wait() }
}

/// Sends the upgrade request once the connection is up, and reports a refusal.
final class UpgradeRequester: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let host: String
    let origin: String?
    let failed: EventLoopPromise<Void>
    init(host: String, origin: String?, failed: EventLoopPromise<Void>) {
        self.host = host
        self.origin = origin
        self.failed = failed
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        headers.add(name: "Content-Length", value: "0")
        if let origin { headers.add(name: "Origin", value: origin) }
        context.write(wrapOutboundOut(.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            failed.fail(SpikeClient.Failure.refused("HTTP \(head.status.code)"))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failed.fail(SpikeClient.Failure.refused("\(error)"))
        context.close(promise: nil)
    }
}
