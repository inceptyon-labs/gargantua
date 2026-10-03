import Foundation
import Security

public protocol CloudAPIKeyStore: Sendable {
    func save(_ apiKey: String) throws
    func read() throws -> String?
    func delete() throws
    func hasKey() throws -> Bool
}

public enum CloudAPIKeyValidator {
    public static func normalized(_ apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isPlausibleAnthropicKey(_ apiKey: String) -> Bool {
        let trimmed = normalized(apiKey)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 24 && !trimmed.contains(where: \.isWhitespace)
    }
}

/// How a keychain key store validates a key before saving. Anthropic enforces
/// the `sk-ant-` shape; `permissive` accepts any non-whitespace token, since
/// OpenAI-compatible providers use wildly different key formats (and local
/// servers may not need one at all — handled at read time, not here).
public enum CloudAPIKeyValidation: Sendable {
    case anthropic
    case permissive

    func accepts(_ trimmed: String) -> Bool {
        switch self {
        case .anthropic:
            return CloudAPIKeyValidator.isPlausibleAnthropicKey(trimmed)
        case .permissive:
            return !trimmed.isEmpty && !trimmed.contains(where: \.isWhitespace)
        }
    }
}

/// Resolves the keychain store for each provider — separate accounts so a key
/// for one provider survives toggling to the other and back.
///
/// An OpenAI-compatible key is stored per endpoint origin (scheme, host,
/// port). The base URL lives in UserDefaults, which any process running as
/// the user can rewrite; with one key for every endpoint, pointing the URL
/// somewhere else (or picking another preset) sent the key there. A key now
/// only goes to the origin it was saved for.
public enum CloudAPIKeyStores {
    public static func store(for configuration: CloudAIConfiguration) -> any CloudAPIKeyStore {
        switch configuration.provider {
        case .anthropic:
            return KeychainCloudAPIKeyStore(account: "anthropic-api-key", validation: .anthropic)
        case .openAICompatible:
            let origin = configuration.resolvedOpenAIBaseURL.flatMap(origin(of:))
            let store = KeychainCloudAPIKeyStore(account: openAIAccount(origin: origin), validation: .permissive)
            migrateLegacyOpenAIKey(to: store, origin: origin)
            return store
        }
    }

    /// Before keys were bound to an origin, the one OpenAI-compatible key was
    /// stored under this account.
    static let legacyOpenAIAccount = "openai-api-key"

    static func openAIAccount(origin: String?) -> String {
        guard let origin else { return legacyOpenAIAccount + "@invalid" }
        return "\(legacyOpenAIAccount)@\(origin)"
    }

    /// `https://api.openai.com:443/v1` → `https://api.openai.com:443`; the
    /// port is spelled out so `:443` and an implicit 443 are the same origin.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }

    /// Carries a key saved before origin binding over to OpenAI's own
    /// endpoint, the one origin it can be trusted for without knowing which
    /// URL it was entered for. With any other endpoint configured, the old
    /// key is left unused and has to be entered again.
    static func migrateLegacyOpenAIKey(
        to store: any CloudAPIKeyStore,
        origin: String?,
        legacy: any CloudAPIKeyStore = KeychainCloudAPIKeyStore(account: legacyOpenAIAccount, validation: .permissive)
    ) {
        let defaultOrigin = URL(string: CloudAIProvider.openAICompatible.defaultBaseURL).flatMap(origin(of:))
        guard origin == defaultOrigin,
              (try? legacy.hasKey()) == true,
              (try? store.hasKey()) != true,
              let key = try? legacy.read() else { return }
        try? store.save(key)
        try? legacy.delete()
    }
}

public struct KeychainCloudAPIKeyStore: CloudAPIKeyStore {
    private let service: String
    private let account: String
    private let validation: CloudAPIKeyValidation

    public init(
        service: String = "com.gargantua.cloud-ai",
        account: String = "anthropic-api-key",
        validation: CloudAPIKeyValidation = .anthropic
    ) {
        self.service = service
        self.account = account
        self.validation = validation
    }

    public func save(_ apiKey: String) throws {
        let trimmed = CloudAPIKeyValidator.normalized(apiKey)
        guard validation.accepts(trimmed) else {
            throw CloudAIError.invalidAPIKey
        }

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8),
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCloudAPIKeyStoreError(status: updateStatus)
        }

        let query = lookup.merging(attributes) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainCloudAPIKeyStoreError(status: status)
        }
    }

    public func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCloudAPIKeyStoreError(status: status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCloudAPIKeyStoreError(status: status)
        }
    }

    /// Existence check that does NOT decrypt the secret. Returning attributes
    /// only (no `kSecReturnData`) means macOS doesn't run the item's ACL, so a
    /// status check — e.g. opening Settings → AI — never raises the "allow
    /// access to your keychain" prompt. The prompt is reserved for `read()`,
    /// when the key is actually used for a request.
    public func hasKey() throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw KeychainCloudAPIKeyStoreError(status: status)
        }
        return true
    }
}

public struct KeychainCloudAPIKeyStoreError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain operation failed with status \(status)."
    }
}
