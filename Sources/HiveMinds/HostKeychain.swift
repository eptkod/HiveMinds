import Foundation
import Security
import Crypto
import HiveMindsNet

/// A host this Mac has paired with. Kept in the Keychain (docs/LINUX-HOST-SPEC.md §6), never in a file.
struct PairedHost: Codable, Identifiable, Hashable {
    /// The host's random id (also in its Bonjour TXT record).
    var id: String
    /// The name it gave at pairing ("cachyos-desktop").
    var name: String
    /// Its certificate's fingerprint, pinned: a different certificate is refused.
    var fingerprint: String
    var token: String
    /// Where it was last reached, for when discovery is off or doesn't find it.
    var address: String
    var port: Int
    /// This Mac's id on that host.
    var deviceID: String
    var pairedAt = Date()
}

/// The Keychain items for hosts: this Mac's device identity (one key and certificate for every host) and one
/// item per paired host. Debug builds can keep them in a file instead (`HIVEMINDS_HOSTS_FILE`), so two copies
/// of the app can be tested side by side without Keychain prompts.
enum HostKeychain {
    private static let service = "HiveMinds host pairing"

    #if DEBUG
    private static let testFile: URL? = ProcessInfo.processInfo.environment["HIVEMINDS_HOSTS_FILE"].map { URL(fileURLWithPath: $0) }
    #else
    private static let testFile: URL? = nil
    #endif

    // MARK: Device identity

    private struct StoredIdentity: Codable {
        var key: Data
        var certificate: Data
    }

    /// This Mac's identity for hosts, made the first time it's needed.
    static func deviceIdentity() throws -> Identity {
        if let data = read("device"), let s = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: s.key) {
            return Identity(key: key, certificate: [UInt8](s.certificate))
        }
        let made = try Identity(commonName: "HiveMinds on \(Host.current().localizedName ?? "a Mac")")
        let data = try JSONEncoder().encode(StoredIdentity(key: made.key.rawRepresentation, certificate: Data(made.certificate)))
        guard write("device", data) else { throw HostKeychainError("Couldn't save this Mac's identity to the Keychain.") }
        return made
    }

    // MARK: Paired hosts

    static func pairedHosts() -> [PairedHost] {
        if let file = testFile {
            return (try? JSONDecoder().decode([PairedHost].self, from: Data(contentsOf: file))) ?? []
        }
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard (item[kSecAttrAccount as String] as? String)?.hasPrefix("host.") == true, let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(PairedHost.self, from: data)
        }.sorted { $0.pairedAt < $1.pairedAt }
    }

    @discardableResult
    static func save(_ host: PairedHost) -> Bool {
        if let file = testFile {
            var all = pairedHosts().filter { $0.id != host.id }
            all.append(host)
            return (try? JSONEncoder().encode(all).write(to: file, options: .atomic)) != nil
        }
        guard let data = try? JSONEncoder().encode(host) else { return false }
        return write("host.\(host.id)", data)
    }

    static func forget(_ hostID: String) {
        if let file = testFile {
            let all = pairedHosts().filter { $0.id != hostID }
            try? JSONEncoder().encode(all).write(to: file, options: .atomic)
            return
        }
        var q = base()
        q[kSecAttrAccount as String] = "host.\(hostID)"
        SecItemDelete(q as CFDictionary)
    }

    // MARK: Keychain

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private static func read(_ account: String) -> Data? {
        if let file = testFile {
            let other = file.deletingPathExtension().appendingPathExtension("\(account).json")
            return try? Data(contentsOf: other)
        }
        var q = base()
        q[kSecAttrAccount as String] = account
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ account: String, _ data: Data) -> Bool {
        if let file = testFile {
            let other = file.deletingPathExtension().appendingPathExtension("\(account).json")
            return (try? data.write(to: other, options: .atomic)) != nil
        }
        var q = base()
        q[kSecAttrAccount as String] = account
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = account == "device" ? "HiveMinds: this Mac's identity for hosts" : "HiveMinds: paired host"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

struct HostKeychainError: Error, LocalizedError {
    var errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
