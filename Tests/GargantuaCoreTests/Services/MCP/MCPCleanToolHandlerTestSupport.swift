import Testing
import Foundation
@testable import GargantuaCore

// MARK: - Shared fixtures

/// Shared fixtures and helpers used across the split MCPCleanToolHandler test suites.
/// Kept at file-scope (not nested in any `@Suite` struct) so multiple test files can
/// share them without inflating any single suite body past the SwiftLint
/// `type_body_length` threshold.
enum MCPCleanTestFixtures {

    // Deterministic audit UUID for wire-assertion. `uuidString` always
    // returns uppercase, so the wire-form string we expect is the uppercase
    // form; tests that decode it back through UUID round-trip freely.
    static let fixedAuditUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000AF01")!
    static var fixedAuditID: String { fixedAuditUUID.uuidString }

    static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    static let defaultConfirmArg: [String: MCPJSONAny] = ["confirm": .bool(true)]

    static func makeResult(
        id: String,
        size: Int64 = 1_000_000,
        safety: SafetyLevel = .safe,
        path: String? = nil,
        name: String? = nil
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: name ?? "name-\(id)",
            path: path ?? "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "test",
            source: SourceAttribution(name: "TestApp"),
            category: "browser_cache"
        )
    }

    static func cacheWith(_ items: [ScanResult]) -> MCPScanSessionCache {
        let cache = MCPScanSessionCache()
        cache.replace(with: items)
        return cache
    }

    /// Ergonomic arguments builder mirroring what the dispatcher would pass in.
    static func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
        MCPToolArguments(dict)
    }

    static func handler(
        cache: MCPScanSessionCache,
        cleaner: @escaping MCPCleanToolHandler.Cleaner = { _, _ in
            CleanupResult(itemResults: [], cleanupMethod: .trash)
        },
        auditUUID: UUID = fixedAuditUUID,
        auditRecorder: MCPCleanToolHandler.AuditRecorder? = nil,
        rateLimiter: MCPRateLimiter? = nil,
        clientID: String? = nil,
        log: MCPDispatcherLog? = nil
    ) -> MCPCleanToolHandler {
        MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: cleaner,
            auditIDGenerator: { auditUUID },
            auditRecorder: auditRecorder,
            rateLimiter: rateLimiter,
            clientIDProvider: { clientID },
            log: log
        )
    }

    static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPCleanOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPCleanOutput.self, from: data)
    }
}

// MARK: - Test capture helpers
//
// Nested under `MCPCleanTestFixtures` to avoid colliding with other test
// files in the module (e.g. MCPScanToolHandlerErrorsTests.swift) that
// declare their own file-private `CapturedFlag` / `CapturedLog`.

extension MCPCleanTestFixtures {

    final class CapturedFlag: @unchecked Sendable {
        var value: Bool = false
    }

    final class CapturedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int = 0
        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    final class CapturedMethod: @unchecked Sendable {
        var value: CleanupMethod?
    }

    final class CapturedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func append(_ entry: String) {
            lock.lock(); entries.append(entry); lock.unlock()
        }
        var joined: String {
            lock.lock(); defer { lock.unlock() }
            return entries.joined(separator: "\n")
        }
    }
}
