import Foundation
import Security

/// Network scopes supported by the MCP SSE server.
public enum MCPServerBindScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Bind only to loopback.
    case localhost
    /// Bind to all interfaces for LAN access.
    case lan

    /// Stable identifier used by SwiftUI controls.
    public var id: String { rawValue }

    /// User-facing bind scope name.
    public var displayName: String {
        switch self {
        case .localhost: return "Localhost"
        case .lan: return "LAN"
        }
    }

    /// User-facing explanation of the bind scope.
    public var detail: String {
        switch self {
        case .localhost:
            return "Binds to 127.0.0.1 only."
        case .lan:
            return "Binds to all interfaces; use a bearer token and TLS reverse proxy for remote clients."
        }
    }

    /// Host string used when starting the network listener.
    public var bindHost: String {
        switch self {
        case .localhost: return "127.0.0.1"
        case .lan: return "0.0.0.0"
        }
    }
}

/// Persisted MCP SSE server settings.
public struct MCPSSEServerConfiguration: Codable, Sendable, Equatable {
    /// Default SSE port used by Gargantua.
    public static let defaultPort = 7_493
    /// Valid TCP port range accepted by settings.
    public static let validPortRange = 1...65_535

    /// Whether the SSE server should run.
    public var isEnabled: Bool
    /// TCP port used by the SSE server.
    public var port: Int
    /// Network bind scope for the SSE server.
    public var bindScope: MCPServerBindScope

    /// Creates an SSE server configuration, normalizing the port into range.
    public init(
        isEnabled: Bool = false,
        port: Int = Self.defaultPort,
        bindScope: MCPServerBindScope = .localhost
    ) {
        self.isEnabled = isEnabled
        self.port = Self.normalizedPort(port)
        self.bindScope = bindScope
    }

    /// Host string derived from the selected bind scope.
    public var bindHost: String { bindScope.bindHost }
    /// Whether incoming requests must present a bearer token.
    public var requiresBearerToken: Bool { bindScope == .lan }

    /// Clamps a port to the valid TCP port range.
    public static func normalizedPort(_ port: Int) -> Int {
        min(max(port, validPortRange.lowerBound), validPortRange.upperBound)
    }

    /// Validates that the configuration can safely start.
    public func validate(hasBearerToken: Bool) throws {
        guard Self.validPortRange.contains(port) else {
            throw MCPSSEConfigurationError.invalidPort(port)
        }
        if requiresBearerToken && !hasBearerToken {
            throw MCPSSEConfigurationError.missingBearerToken
        }
    }
}

/// Validation errors for MCP SSE server configuration.
public enum MCPSSEConfigurationError: Error, LocalizedError, Equatable, Sendable {
    /// The configured TCP port is outside the valid range.
    case invalidPort(Int)
    /// LAN binding was requested without a stored bearer token.
    case missingBearerToken

    /// Localized user-facing error description.
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "MCP SSE port \(port) is outside the valid TCP port range."
        case .missingBearerToken:
            return "LAN MCP SSE requires a bearer token before it can start."
        }
    }
}

/// Thread-safe persistence wrapper for MCP SSE configuration.
public final class MCPSSEConfigurationStore: @unchecked Sendable {
    /// UserDefaults key used for the encoded SSE configuration.
    public static let defaultsKey = "mcpSSEConfiguration"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Creates a configuration store backed by the supplied defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads saved SSE configuration or returns defaults.
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

    /// Saves the supplied SSE configuration after normalizing it.
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

/// Storage abstraction for the MCP SSE bearer token.
public protocol MCPBearerTokenStore: Sendable {
    func save(_ token: String) throws
    func read() throws -> String?
    func delete() throws
    func hasToken() throws -> Bool
}

/// Normalization and plausibility checks for MCP bearer tokens.
public enum MCPBearerTokenValidator {
    /// Trims surrounding whitespace from a token.
    public static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns whether the token is long enough and contains no whitespace.
    public static func isPlausible(_ token: String) -> Bool {
        let trimmed = normalized(token)
        return trimmed.count >= 24 && !trimmed.contains(where: \.isWhitespace)
    }
}

/// Secure random bearer token generator for MCP SSE LAN mode.
public enum MCPBearerTokenGenerator {
    /// Generates a URL-safe token with the Gargantua prefix.
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

/// Keychain-backed bearer token store for MCP SSE.
public struct KeychainMCPBearerTokenStore: MCPBearerTokenStore {
    private let service: String
    private let account: String

    /// Creates a keychain token store for the supplied service and account.
    public init(
        service: String = "com.gargantua.mcp",
        account: String = "sse-bearer-token"
    ) {
        self.service = service
        self.account = account
    }

    /// Saves or replaces the bearer token in the keychain.
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

    /// Reads the bearer token from the keychain when present.
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

    /// Deletes the bearer token from the keychain.
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

    /// Returns whether a bearer token exists.
    public func hasToken() throws -> Bool {
        try read() != nil
    }
}

/// Errors raised by bearer token storage and generation.
public enum MCPBearerTokenStoreError: Error, LocalizedError, Equatable, Sendable {
    /// The token failed local plausibility validation.
    case invalidToken
    /// Secure random generation failed with an OSStatus.
    case random(OSStatus)
    /// A keychain operation failed with an OSStatus.
    case keychain(OSStatus)

    /// Localized user-facing error description.
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

/// High-level bearer token manager for reads, rotation, and revocation.
public struct MCPBearerTokenManager: Sendable {
    private let store: any MCPBearerTokenStore
    private let generator: @Sendable () throws -> String

    /// Creates a token manager with injected storage and token generation.
    public init(
        store: any MCPBearerTokenStore = KeychainMCPBearerTokenStore(),
        generator: @escaping @Sendable () throws -> String = { try MCPBearerTokenGenerator.generate() }
    ) {
        self.store = store
        self.generator = generator
    }

    /// Returns whether a token exists in storage.
    public func hasToken() throws -> Bool {
        try store.hasToken()
    }

    /// Reads the current token, if one exists.
    public func readToken() throws -> String? {
        try store.read()
    }

    @discardableResult
    /// Returns an existing token or creates and stores a new one.
    public func ensureToken() throws -> String {
        if let existing = try store.read() {
            return existing
        }
        return try rotateToken()
    }

    @discardableResult
    /// Generates and stores a replacement token.
    public func rotateToken() throws -> String {
        let token = try generator()
        try store.save(token)
        return token
    }

    /// Deletes the stored bearer token.
    public func revokeToken() throws {
        try store.delete()
    }
}

/// Authorization helpers for MCP SSE bearer-token requests.
public enum MCPSSEAuthorization {
    /// Extracts a bearer token from an HTTP Authorization header.
    public static func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader else { return nil }
        let trimmed = authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return nil }
        let token = String(trimmed.dropFirst("Bearer ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Returns whether the request is authorized for the supplied configuration.
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
