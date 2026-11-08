import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL
#if canImport(Glibc)
import Glibc
#endif

/// A long-lived key and self-signed certificate: the host's, or a device's. Peers know each other by the
/// certificate's fingerprint (docs/HOST-PROTOCOL.md §1).
/// `@unchecked Sendable`: both parts are immutable values (a private key and bytes), safe to share between threads;
/// Crypto just doesn't mark its key types Sendable on every platform.
package struct Identity: @unchecked Sendable {
    package let key: P256.Signing.PrivateKey
    /// The certificate, DER-encoded.
    package let certificate: [UInt8]

    package var fingerprint: String { Identity.fingerprint(of: certificate) }

    /// Makes a new identity.
    package init(commonName: String) throws {
        key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(commonName) }
        let now = Date()
        let cert = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86400), notValidAfter: now.addingTimeInterval(20 * 365 * 86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) },
            issuerPrivateKey: .init(key))
        var ser = DER.Serializer()
        try ser.serialize(cert)
        certificate = ser.serializedBytes
    }

    package init(key: P256.Signing.PrivateKey, certificate: [UInt8]) {
        self.key = key
        self.certificate = certificate
    }

    /// Loads the identity kept in `folder` (key.pem, cert.pem), making one the first time. The folder is made
    /// owner-only (0700) and both files 0600.
    package static func loadOrCreate(in folder: URL, commonName: String) throws -> Identity {
        let keyFile = folder.appendingPathComponent("key.pem"), certFile = folder.appendingPathComponent("cert.pem")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chmod(folder.path, 0o700)
        if FileManager.default.fileExists(atPath: keyFile.path), FileManager.default.fileExists(atPath: certFile.path) {
            let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: keyFile, encoding: .utf8))
            let cert = try Certificate(pemEncoded: String(contentsOf: certFile, encoding: .utf8))
            var ser = DER.Serializer()
            try ser.serialize(cert)
            guard cert.publicKey == Certificate.PublicKey(key.publicKey) else {
                throw IdentityError("\(certFile.path) doesn't belong to \(keyFile.path). Remove both to make a new identity (devices will need to pair again).")
            }
            return Identity(key: key, certificate: ser.serializedBytes)
        }
        let made = try Identity(commonName: commonName)
        try write(made.key.pemRepresentation, to: keyFile)
        try write(try Certificate(derEncoded: made.certificate).serializeAsPEM().pemString, to: certFile)
        return made
    }

    private static func write(_ s: String, to url: URL) throws {
        // Created owner-only before anything is written to it.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw IdentityError("Couldn't write \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let bytes = Array(s.utf8)
        guard bytes.withUnsafeBytes({ Glibc_write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
            throw IdentityError("Couldn't write \(url.path)")
        }
    }

    /// SHA-256 of a DER certificate, 64 uppercase hex digits.
    package static func fingerprint(of der: [UInt8]) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// How a fingerprint is shown to people: the first 16 digits in groups of 4 ("7F3A-91C2-04BE-5D10").
    package static func display(_ fingerprint: String) -> String {
        let s = Array(fingerprint.prefix(16))
        return stride(from: 0, to: s.count, by: 4).map { String(s[$0..<min($0 + 4, s.count)]) }.joined(separator: "-")
    }

    var nioCertificate: NIOSSLCertificate { get throws { try NIOSSLCertificate(bytes: certificate, format: .der) } }
    var nioKey: NIOSSLPrivateKey { get throws { try NIOSSLPrivateKey(bytes: Array(key.derRepresentation), format: .der) } }
}

package struct IdentityError: Error, CustomStringConvertible {
    package var description: String
    init(_ s: String) { description = s }
}

@inline(__always)
private func Glibc_write(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { write(fd, p, n) }
