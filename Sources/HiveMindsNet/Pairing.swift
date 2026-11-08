import Foundation
import Crypto
import CSpake2

/// One side of a pairing exchange (docs/HOST-PROTOCOL.md §2.3): BoringSSL's SPAKE2 on Curve25519, with each
/// side's identity being the certificate fingerprints as it saw them in TLS, then HMAC proofs over both.
package final class PairingExchange: @unchecked Sendable {
    package enum Role: Sendable { case client, host }

    private let ctx: OpaquePointer
    private let role: Role
    private let clientFP: String
    private let hostFP: String
    /// Our SPAKE2 message, for the other side.
    package let message: [UInt8]
    private var key: SymmetricKey?

    package init(role: Role, clientFingerprint: String, hostFingerprint: String, code: String) {
        self.role = role
        clientFP = clientFingerprint
        hostFP = hostFingerprint
        let mine = Array((role == .client ? "hiveminds-v1 client \(clientFP)" : "hiveminds-v1 host \(hostFP)").utf8)
        let theirs = Array((role == .client ? "hiveminds-v1 host \(hostFP)" : "hiveminds-v1 client \(clientFP)").utf8)
        ctx = CNIOBoringSSL_SPAKE2_CTX_new(role == .client ? spake2_role_alice : spake2_role_bob,
                                           mine, mine.count, theirs, theirs.count)
        var out = [UInt8](repeating: 0, count: 32)
        var len = 0
        let pw = Array(code.utf8)
        let ok = CNIOBoringSSL_SPAKE2_generate_msg(ctx, &out, &len, out.count, pw, pw.count)
        precondition(ok == 1, "SPAKE2 couldn't make its message")
        message = Array(out[..<len])
    }

    deinit { CNIOBoringSSL_SPAKE2_CTX_free(ctx) }

    /// Takes the other side's message. False when it's malformed. (A wrong code isn't an error here: it gives a
    /// different key, which the proofs then catch.)
    package func receive(_ theirs: [UInt8]) -> Bool {
        guard key == nil, theirs.count == 32 else { return false }
        var out = [UInt8](repeating: 0, count: 64)
        var len = 0
        guard CNIOBoringSSL_SPAKE2_process_msg(ctx, &out, &len, out.count, theirs, theirs.count) == 1 else { return false }
        key = SymmetricKey(data: out[..<len])
        return true
    }

    private func proof(_ who: String) -> [UInt8] {
        guard let key else { return [] }
        return Array(HMAC<SHA256>.authenticationCode(for: Array("hiveminds-pair-v1|\(who)|\(clientFP)|\(hostFP)".utf8), using: key))
    }

    /// The proof this side sends.
    package var myProof: [UInt8] { proof(role == .client ? "client" : "host") }

    /// Whether the other side's proof shows it had the same code, over this connection.
    package func checks(_ theirs: [UInt8]) -> Bool {
        let expected = proof(role == .client ? "host" : "client")
        return !expected.isEmpty && constantTimeEqual(expected, theirs)
    }
}

package func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

/// A pairing code shown on the host: 6 digits, valid 60 s, single use, 3 tries.
package struct PairingCode: Sendable {
    package let digits: String
    package let expires: Date
    package private(set) var triesLeft = 3
    package private(set) var used = false

    package init(now: Date = Date(), lifetime: TimeInterval = 60) {
        var rng = SystemRandomNumberGenerator()
        digits = String(format: "%06d", Int.random(in: 0...999_999, using: &rng))
        expires = now.addingTimeInterval(lifetime)
    }

    package init(digits: String, expires: Date) {
        self.digits = digits
        self.expires = expires
    }

    package func isUsable(at now: Date = Date()) -> Bool { !used && triesLeft > 0 && now < expires }

    /// "482 913"
    package var display: String { "\(digits.prefix(3)) \(digits.suffix(3))" }

    /// A wrong proof: one try fewer.
    package mutating func failedTry() { triesLeft = max(0, triesLeft - 1) }
    /// A right proof: the code can't be used again.
    package mutating func use() { used = true }
}

/// Device tokens: 32 random bytes, base64url without padding. Only their SHA-256 is kept.
package enum DeviceToken {
    package static func make() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return base64url(bytes)
    }

    package static func hash(_ token: String) -> String {
        SHA256.hash(data: Array(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    package static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Random ids: 16 hex digits.
package func randomHexID(_ bytes: Int = 8) -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
}
