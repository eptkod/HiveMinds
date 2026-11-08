import Foundation
import HiveMindsProtocol
#if canImport(Glibc)
import Glibc
#endif

/// A device paired with this host. The token itself is never kept, only its SHA-256.
package struct PairedDevice: Codable, Hashable, Sendable {
    package var id: String
    package var name: String
    /// Its certificate's fingerprint: the token only works with this certificate.
    package var fingerprint: String
    package var tokenHash: String
    package var pairedAt: Date
    package var lastUsed: Date

    package var info: DeviceInfo { DeviceInfo(id: id, name: name) }
}

/// The paired devices, kept in a 0600 JSON file. Not thread-safe: use it from one queue.
package final class DeviceRegistry {
    /// A token unused this long stops working (docs/LINUX-HOST-SPEC.md §6).
    package static let maxIdle: TimeInterval = 90 * 86400

    private let file: URL?
    package private(set) var devices: [PairedDevice] = []

    package init(file: URL?) throws {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            devices = try d.decode([PairedDevice].self, from: Data(contentsOf: file))
        }
    }

    private func save() {
        guard let file else { return }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(devices) else { return }
        try? data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// Removes devices that haven't connected for `maxIdle`, and returns them.
    @discardableResult
    package func expire(now: Date = Date()) -> [PairedDevice] {
        let gone = devices.filter { now.timeIntervalSince($0.lastUsed) > DeviceRegistry.maxIdle }
        guard !gone.isEmpty else { return [] }
        devices.removeAll { now.timeIntervalSince($0.lastUsed) > DeviceRegistry.maxIdle }
        save()
        return gone
    }

    /// The device this token and certificate belong to, or nil. A match is marked as used now.
    package func authenticate(token: String, fingerprint: String, now: Date = Date()) -> PairedDevice? {
        expire(now: now)
        let hash = Array(DeviceToken.hash(token).utf8)
        // Compare every entry in constant time, so timing doesn't say how close a guess was.
        var found: Int?
        for (i, d) in devices.enumerated() where constantTimeEqual(Array(d.tokenHash.utf8), hash) && d.fingerprint == fingerprint {
            found = i
        }
        guard let i = found else { return nil }
        devices[i].lastUsed = now
        save()
        return devices[i]
    }

    /// Pairs a device: returns its record and its token (which is shown only this once). A device pairing
    /// again with the same certificate replaces its old record.
    package func add(name: String, fingerprint: String, now: Date = Date()) -> (PairedDevice, String) {
        let token = DeviceToken.make()
        devices.removeAll { $0.fingerprint == fingerprint }
        var id = randomHexID()
        while devices.contains(where: { $0.id == id }) { id = randomHexID() }
        let d = PairedDevice(id: id, name: name, fingerprint: fingerprint, tokenHash: DeviceToken.hash(token), pairedAt: now, lastUsed: now)
        devices.append(d)
        save()
        return (d, token)
    }

    /// Removes the devices with this name or id (or id prefix), and returns them.
    package func revoke(_ nameOrID: String) -> [PairedDevice] {
        let gone = devices.filter { $0.name == nameOrID || $0.id == nameOrID || (nameOrID.count >= 4 && $0.id.hasPrefix(nameOrID)) }
        guard !gone.isEmpty else { return [] }
        devices.removeAll { gone.contains($0) }
        save()
        return gone
    }

    /// Picks up changes made by another process (`hiveminds-host devices revoke`).
    package func reload() throws {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { devices = []; return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        devices = try d.decode([PairedDevice].self, from: Data(contentsOf: file))
    }
}

/// The host's side of pairing (docs/HOST-PROTOCOL.md §2.3): the code on show, each connection's exchange,
/// and the owner's yes. Not thread-safe: use it from one queue.
package final class PairingDesk {
    package let hostFingerprint: String
    package private(set) var code: PairingCode?
    private var exchanges: [UUID: (exchange: PairingExchange, clientFP: String, name: String)] = [:]
    /// The connection whose pairing is waiting for the owner, if any.
    package private(set) var waiting: UUID?

    package init(hostFingerprint: String) {
        self.hostFingerprint = hostFingerprint
    }

    /// Shows a new code (the old one stops working).
    @discardableResult
    package func newCode(now: Date = Date(), lifetime: TimeInterval = 60) -> PairingCode {
        let c = PairingCode(now: now, lifetime: lifetime)
        code = c
        return c
    }

    /// For tests: a known code.
    package func setCode(_ c: PairingCode) { code = c }

    /// `pairStart` from a connection. Returns the host's SPAKE2 message, or the error to send.
    package func start(_ connection: UUID, deviceName: String, clientFingerprint: String, spake: [UInt8], now: Date = Date()) -> Result<[UInt8], ErrorInfo> {
        guard var c = code, c.isUsable(at: now) else {
            if let c = code, c.triesLeft == 0 || c.used {
                return .failure(ErrorInfo("tooManyTries", "That pairing code is used up. Press p on the host for a new one."))
            }
            return .failure(ErrorInfo("noCode", "There's no pairing code showing on the host. Press p there for one."))
        }
        if let w = waiting, w != connection {
            return .failure(ErrorInfo("busy", "Another device is pairing with this host right now. Try again in a minute."))
        }
        let ex = PairingExchange(role: .host, clientFingerprint: clientFingerprint, hostFingerprint: hostFingerprint, code: c.digits)
        guard ex.receive(spake) else {
            // A malformed message still costs a try, so it can't be used to probe for free.
            c.failedTry()
            code = c
            return .failure(ErrorInfo("badRequest", "That pairing message didn't make sense.", triesLeft: c.triesLeft))
        }
        exchanges[connection] = (ex, clientFingerprint, String(deviceName.prefix(80)))
        return .success(ex.message)
    }

    package enum Confirmation {
        /// The code was right: ask the owner about this device.
        case askOwner(name: String, fingerprint: String)
        case refused(ErrorInfo)
    }

    /// `pairConfirm` from a connection.
    package func confirm(_ connection: UUID, proof: [UInt8], now: Date = Date()) -> Confirmation {
        guard let state = exchanges.removeValue(forKey: connection) else {
            return .refused(ErrorInfo("badRequest", "Send pairStart first."))
        }
        guard var c = code, c.isUsable(at: now) else {
            return .refused(ErrorInfo("tooManyTries", "That pairing code is used up or expired. Press p on the host for a new one."))
        }
        guard state.exchange.checks(proof) else {
            c.failedTry()
            code = c
            if c.triesLeft == 0 {
                return .refused(ErrorInfo("tooManyTries", "That was the last try for this code. Press p on the host for a new one.", triesLeft: 0))
            }
            return .refused(ErrorInfo("wrongCode", "That isn't the code showing on the host.", triesLeft: c.triesLeft))
        }
        c.use()
        code = c
        waiting = connection
        pendingProof = (connection, state.exchange, state.clientFP)
        return .askOwner(name: state.name, fingerprint: state.clientFP)
    }

    private var pendingProof: (UUID, PairingExchange, String)?

    /// The owner's answer for the waiting connection. On yes, the host's proof to send in `paired`.
    package func ownerAnswered(_ connection: UUID, allowed: Bool) -> [UInt8]? {
        defer {
            if waiting == connection { waiting = nil }
            if pendingProof?.0 == connection { pendingProof = nil }
        }
        guard allowed, let p = pendingProof, p.0 == connection else { return nil }
        return p.1.myProof
    }

    /// A connection went away: forget its exchange (and its wait for the owner).
    package func forget(_ connection: UUID) {
        exchanges[connection] = nil
        if waiting == connection { waiting = nil; pendingProof = nil }
    }
}
