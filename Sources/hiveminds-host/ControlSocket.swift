import Foundation
import CHiveMindsSystem
#if canImport(Glibc)
import Glibc
#endif

// A Unix socket that lets `hiveminds-host status` and the debug commands talk to a running `serve`, on this machine
// only: it lives in the owner-only state folder, the socket itself is 0600, and a connection from any other user is
// closed. One JSON object per line each way. Nothing here is reachable from the network.

private func makeAddress(_ path: String) throws -> (sockaddr_un, socklen_t) {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw HostError("The control socket's path is too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
}

private func setNonBlockingCloseOnExec(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
}

/// Whether the process at the other end runs as the same user as us.
private func peerIsUs(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    return hiveminds_socket_peer_uid(fd, &uid) == 0 && uid == getuid()
}

private func encodeLine(_ object: [String: Any]) -> [UInt8] {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return Array(data) + [0x0A]
}

/// One client of the control socket.
final class ControlConnection {
    private let fd: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private var outgoing: [UInt8] = []
    private var writer: DispatchSourceWrite?
    private(set) var isOpen = true
    private var closeAfterSend = false
    var onClose: [() -> Void] = []

    fileprivate init(fd: Int32, queue: DispatchQueue, onRequest: @escaping (ControlConnection, [String: Any]) -> Void) {
        self.fd = fd
        self.queue = queue
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        r.setEventHandler { [weak self] in self?.readAvailable(onRequest) }
        r.setCancelHandler { close(fd) }
        reader = r
        r.resume()
    }

    private func readAvailable(_ onRequest: (ControlConnection, [String: Any]) -> Void) {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 1 << 20 { return shut() }
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            if n < 0 && errno == EINTR { continue }
            return shut()
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                send(["error": "That wasn't a request this host understands."])
                continue
            }
            onRequest(self, object)
        }
    }

    /// Sends one reply. Call on the server's queue.
    func send(_ object: [String: Any]) {
        guard isOpen else { return }
        outgoing += encodeLine(object)
        flush()
    }

    /// Sends a last reply, then closes.
    func finish(_ object: [String: Any]) {
        send(object)
        closeAfterSend = true
        if outgoing.isEmpty { shut() }
    }

    private func flush() {
        while !outgoing.isEmpty {
            let n = outgoing.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { outgoing.removeFirst(n); continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    w.setEventHandler { [weak self] in self?.flush() }
                    writer = w
                    w.resume()
                }
                return
            }
            return shut()
        }
        writer?.cancel()
        writer = nil
        if closeAfterSend { shut() }
    }

    func shut() {
        guard isOpen else { return }
        isOpen = false
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
        let callbacks = onClose
        onClose = []
        for c in callbacks { c() }
    }
}

/// The listening end, in `serve`.
final class ControlServer {
    private let fd: Int32
    private let path: String
    private let source: DispatchSourceRead
    private var connections: [ObjectIdentifier: ControlConnection] = [:]

    init(path: String, queue: DispatchQueue, onRequest: @escaping (ControlConnection, [String: Any]) -> Void) throws {
        self.path = path
        let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard s >= 0 else { throw HostError("Couldn't make the control socket: \(String(cString: strerror(errno)))") }
        setNonBlockingCloseOnExec(s)
        // A socket left by a host that didn't shut down cleanly. Only one host runs at a time (see the lock).
        unlink(path)
        var (addr, len) = try makeAddress(path)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(s, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(s)
            throw HostError("Couldn't open the control socket at \(path): \(message)")
        }
        fd = s
        source = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(s, nil, nil)
                guard client >= 0 else { break }
                setNonBlockingCloseOnExec(client)
                guard peerIsUs(client) else { close(client); continue }
                let c = ControlConnection(fd: client, queue: queue, onRequest: onRequest)
                let key = ObjectIdentifier(c)
                c.onClose.append { [weak self] in self?.connections[key] = nil }
                self.connections[key] = c
            }
        }
        source.setCancelHandler { close(s) }
        source.resume()
    }

    func shut() {
        for c in connections.values { c.shut() }
        connections = [:]
        source.cancel()
        unlink(path)
    }
}

/// The asking end, for the CLI commands: sends one request and reads replies until `keepReading` says stop
/// or the host closes the connection.
enum ControlClient {
    /// Nil when no host is listening.
    static func request(_ path: String, _ object: [String: Any], keepReading: ([String: Any]) -> Bool = { _ in false }) throws -> [String: Any]? {
        let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard s >= 0 else { throw HostError("Couldn't make a socket: \(String(cString: strerror(errno)))") }
        defer { close(s) }
        var (addr, len) = try makeAddress(path)
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) } }
        guard connected == 0 else { return nil }
        let line = encodeLine(object)
        _ = line.withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
        var buffer = Data()
        var last: [String: Any]?
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(s, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return last }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let l = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let reply = try? JSONSerialization.jsonObject(with: l) as? [String: Any] else { continue }
                last = reply
                if !keepReading(reply) { return reply }
            }
        }
    }
}

// SOCK_STREAM is an Int32 on macOS and an enum on Linux.
#if os(Linux)
private extension __socket_type { var rawValueCompat: UInt32 { rawValue } }
#else
private extension Int32 { var rawValueCompat: Int32 { self } }
#endif
