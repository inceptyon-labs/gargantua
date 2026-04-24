import Foundation
import Security

public enum MCPServerBindScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case localhost
    case lan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localhost: return "Localhost"
        case .lan: return "LAN"
        }
    }

    public var detail: String {
        switch self {
        case .localhost:
            return "Binds to 127.0.0.1 only."
        case .lan:
            return "Binds to all interfaces and requires a bearer token."
        }
    }

    public var bindHost: String {
        switch self {
        case .localhost: return "127.0.0.1"
        case .lan: return "0.0.0.0"
        }
    }
}

public struct MCPSSEServerConfiguration: Codable, Sendable, Equatable {
    public static let defaultPort = 7_493
    public static let validPortRange = 1...65_535

    public var isEnabled: Bool
    public var port: Int
    public var bindScope: MCPServerBindScope

    public init(
        isEnabled: Bool = false,
        port: Int = Self.defaultPort,
        bindScope: MCPServerBindScope = .localhost
    ) {
        self.isEnabled = isEnabled
        self.port = Self.normalizedPort(port)
        self.bindScope = bindScope
    }

    public var bindHost: String { bindScope.bindHost }
    public var requiresBearerToken: Bool { bindScope == .lan }

    public static func normalizedPort(_ port: Int) -> Int {
        min(max(port, validPortRange.lowerBound), validPortRange.upperBound)
    }

    public func validate(hasBearerToken: Bool) throws {
        guard Self.validPortRange.contains(port) else {
            throw MCPSSEConfigurationError.invalidPort(port)
        }
        if requiresBearerToken && !hasBearerToken {
            throw MCPSSEConfigurationError.missingBearerToken
        }
    }
}

public enum MCPSSEConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case invalidPort(Int)
    case missingBearerToken

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "MCP SSE port \(port) is outside the valid TCP port range."
        case .missingBearerToken:
            return "LAN MCP SSE requires a bearer token before it can start."
        }
    }
}

public final class MCPSSEConfigurationStore: @unchecked Sendable {
    public static let defaultsKey = "mcpSSEConfiguration"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MCPSSEServerConfiguration {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(MCPSSEServerConfiguration.self, from: data)
        else {
            return MCPSSEServerConfiguration()
        }
        return MCPSSEServerConfiguration(
            isEnabled: decoded.isEnabled,
            port: decoded.port,
            bindScope: decoded.bindScope
        )
    }

    public func save(_ configuration: MCPSSEServerConfiguration) {
        lock.lock()
        defer { lock.unlock() }

        let normalized = MCPSSEServerConfiguration(
            isEnabled: configuration.isEnabled,
            port: configuration.port,
            bindScope: configuration.bindScope
        )
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public protocol MCPBearerTokenStore: Sendable {
    func save(_ token: String) throws
    func read() throws -> String?
    func delete() throws
    func hasToken() throws -> Bool
}

public enum MCPBearerTokenValidator {
    public static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isPlausible(_ token: String) -> Bool {
        let trimmed = normalized(token)
        return trimmed.count >= 24 && !trimmed.contains(where: \.isWhitespace)
    }
}

public enum MCPBearerTokenGenerator {
    public static func generate(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MCPBearerTokenStoreError.random(status)
        }

        let encoded = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "gtua_\(encoded)"
    }
}

public struct KeychainMCPBearerTokenStore: MCPBearerTokenStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.gargantua.mcp",
        account: String = "sse-bearer-token"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ token: String) throws {
        let trimmed = MCPBearerTokenValidator.normalized(token)
        guard MCPBearerTokenValidator.isPlausible(trimmed) else {
            throw MCPBearerTokenStoreError.invalidToken
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
            throw MCPBearerTokenStoreError.keychain(updateStatus)
        }

        let query = lookup.merging(attributes) { _, new in new }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MCPBearerTokenStoreError.keychain(status)
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
            throw MCPBearerTokenStoreError.keychain(status)
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
            throw MCPBearerTokenStoreError.keychain(status)
        }
    }

    public func hasToken() throws -> Bool {
        try read() != nil
    }
}

public enum MCPBearerTokenStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidToken
    case random(OSStatus)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "MCP bearer token must be at least 24 non-whitespace characters."
        case .random(let status):
            return "Secure bearer token generation failed with status \(status)."
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain operation failed with status \(status)."
        }
    }
}

public struct MCPBearerTokenManager: Sendable {
    private let store: any MCPBearerTokenStore
    private let generator: @Sendable () throws -> String

    public init(
        store: any MCPBearerTokenStore = KeychainMCPBearerTokenStore(),
        generator: @escaping @Sendable () throws -> String = { try MCPBearerTokenGenerator.generate() }
    ) {
        self.store = store
        self.generator = generator
    }

    public func hasToken() throws -> Bool {
        try store.hasToken()
    }

    public func readToken() throws -> String? {
        try store.read()
    }

    @discardableResult
    public func ensureToken() throws -> String {
        if let existing = try store.read() {
            return existing
        }
        return try rotateToken()
    }

    @discardableResult
    public func rotateToken() throws -> String {
        let token = try generator()
        try store.save(token)
        return token
    }

    public func revokeToken() throws {
        try store.delete()
    }
}

public enum MCPSSEAuthorization {
    public static func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader else { return nil }
        let trimmed = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return nil }
        let token = String(trimmed.dropFirst("Bearer ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public static func isAuthorized(
        authorizationHeader: String?,
        configuration: MCPSSEServerConfiguration,
        storedToken: String?
    ) -> Bool {
        guard configuration.requiresBearerToken else { return true }
        guard let storedToken,
              let presented = bearerToken(from: authorizationHeader)
        else {
            return false
        }
        return constantTimeEquals(presented, storedToken)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let maxCount = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count

        for index in 0..<maxCount {
            let lhsByte = index < lhsBytes.count ? Int(lhsBytes[index]) : 0
            let rhsByte = index < rhsBytes.count ? Int(rhsBytes[index]) : 0
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}
