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

public struct KeychainCloudAPIKeyStore: CloudAPIKeyStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.gargantua.cloud-ai",
        account: String = "anthropic-api-key"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ apiKey: String) throws {
        let trimmed = CloudAPIKeyValidator.normalized(apiKey)
        guard CloudAPIKeyValidator.isPlausibleAnthropicKey(trimmed) else {
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

    public func hasKey() throws -> Bool {
        try read() != nil
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
