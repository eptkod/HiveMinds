import Foundation
import Security

/// How an agent's tool signs in: through your plan's login (`claude` / `codex login`), or with an API key
/// you pay for per token. API keys live in the macOS Keychain, never in a file.
enum SignIn: String, CaseIterable, Identifiable {
    case plan, apiKey
    var id: String { rawValue }

    static func current(for provider: Provider) -> SignIn {
        let stored = UserDefaults.standard.string(forKey: SettingKey.signIn(provider)) ?? SettingDefault.signIn
        return SignIn(rawValue: stored) ?? .plan
    }

    /// The key to use for this provider, or nil when it signs in through its plan (or no key is saved).
    static func apiKey(for provider: Provider) -> String? {
        current(for: provider) == .apiKey ? APIKeys.get(provider) : nil
    }

    /// The environment variable HiveMinds hands the key over in. It's its own name, so it doesn't change
    /// how `claude` or `codex` behave when you run them yourself.
    static func envName(for provider: Provider) -> String {
        switch provider {
        case .claude: "HIVEMINDS_ANTHROPIC_KEY"
        case .codex: "HIVEMINDS_OPENAI_KEY"
        }
    }

    /// The environment that carries the key, if this provider uses one.
    static func environment(for provider: Provider) -> [String: String] {
        guard let key = apiKey(for: provider) else { return [:] }
        return [envName(for: provider): key]
    }

    /// Codex: point it at the OpenAI API with the key from our variable, leaving its own login alone.
    static var codexArgs: [String] {
        guard apiKey(for: .codex) != nil else { return [] }
        return ["-c", "model_provider=\"hiveminds-openai\"",
                "-c", "model_providers.hiveminds-openai={name=\"OpenAI API key\",base_url=\"https://api.openai.com/v1\","
                    + "env_key=\"\(envName(for: .codex))\",wire_api=\"responses\"}"]
    }
}

/// API keys in the Keychain, one per provider. Read once, then kept in memory.
enum APIKeys {
    private static let service = "HiveMinds API key"
    nonisolated(unsafe) private static var cache: [Provider: String?] = [:]
    private static let lock = NSLock()

    static func get(_ provider: Provider) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[provider] { return cached }
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let key = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[provider] = key
        return key
    }

    @discardableResult
    static func set(_ key: String, for provider: Provider) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(provider) as CFDictionary)
        var item = baseQuery(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "HiveMinds \(provider.label) API key"
        let ok = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        cache[provider] = ok ? key : nil
        return ok
    }

    static func remove(_ provider: Provider) {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(baseQuery(provider) as CFDictionary)
        cache[provider] = .some(nil)
    }

    /// The last few characters, so you can tell which key is saved without showing it.
    static func hint(_ provider: Provider) -> String? {
        guard let key = get(provider) else { return nil }
        return "…" + key.suffix(4)
    }

    private static func baseQuery(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
}
