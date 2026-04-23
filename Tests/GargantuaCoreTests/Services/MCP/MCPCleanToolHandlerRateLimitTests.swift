import Testing
import Foundation
@testable import GargantuaCore

// Rate-limit coverage for `MCPCleanToolHandler` — Phase 3 infrastructure
// (bean `gargantua-afft`). Paired with `MCPCleanToolHandlerAuditTests`.
@Suite("MCP clean tool handler — rate limit")
struct MCPCleanToolHandlerRateLimitTests {

    // MARK: Fixtures

    private static func makeResult(
        id: String,
        size: Int64 = 1_000_000,
        safety: SafetyLevel = .safe
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "name-\(id)",
            path: "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "test",
            source: SourceAttribution(name: "TestApp"),
            category: "browser_cache"
        )
    }

    private static func cacheWith(_ items: [ScanResult]) -> MCPScanSessionCache {
        let cache = MCPScanSessionCache()
        cache.replace(with: items)
        return cache
    }

    private func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
        MCPToolArguments(dict)
    }

    private func handler(
        cache: MCPScanSessionCache,
        cleaner: @escaping MCPCleanToolHandler.Cleaner = { _, _ in
            CleanupResult(itemResults: [], cleanupMethod: .trash)
        },
        auditRecorder: MCPCleanToolHandler.AuditRecorder? = nil,
        rateLimiter: MCPRateLimiter? = nil,
        clientID: String? = nil
    ) -> MCPCleanToolHandler {
        MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: cleaner,
            auditRecorder: auditRecorder,
            rateLimiter: rateLimiter,
            clientIDProvider: { clientID }
        )
    }

    // MARK: Tests

    @Test("rate limiter allows first op but rejects second within the window")
    func rateLimiterRejectsSecondOp() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let limiter = MCPRateLimiter(window: 60, maxOps: 1)
        let subject = handler(
            cache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            rateLimiter: limiter,
            clientID: "claude-code"
        )

        _ = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))

        do {
            _ = try subject.handle(arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("second op should be rate-limited")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.lowercased().contains("rate limit"))
            #expect(message.contains("Retry in") || message.contains("retry in"))
            #expect(message.contains("Cool-down") || message.contains("cool-down"))
        }
    }

    @Test("rate limiter is not consulted for dry-run requests")
    func rateLimiterNotConsultedOnDryRun() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let limiter = MCPRateLimiter(window: 60, maxOps: 1)
        let subject = handler(
            cache: cache,
            rateLimiter: limiter,
            clientID: "claude-code"
        )

        for _ in 0..<5 {
            _ = try subject.handle(arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
                "dry_run": .bool(true),
            ]))
        }

        #expect(limiter.eventCount(clientID: "claude-code", tool: "clean") == 0)
    }

    @Test("rate limiter is scoped per-client — client A exhausting budget does not affect client B")
    func rateLimiterPerClient() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let limiter = MCPRateLimiter(window: 60, maxOps: 1)
        let clientA = handler(
            cache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            rateLimiter: limiter,
            clientID: "client-a"
        )
        let clientB = handler(
            cache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            rateLimiter: limiter,
            clientID: "client-b"
        )

        _ = try clientA.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))

        do {
            _ = try clientA.handle(arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("client A should be rate-limited")
        } catch MCPToolError.invalidParams {
            // expected
        }

        let bResult = try clientB.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(bResult.isError == false)
    }

    @Test("rate-limited rejection does not write an audit entry")
    func rateLimitedAttemptNotAudited() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let limiter = MCPRateLimiter(window: 60, maxOps: 1)
        let audit = AuditCapture()
        let subject = handler(
            cache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            auditRecorder: { try audit.record($0) },
            rateLimiter: limiter,
            clientID: "claude-code"
        )

        _ = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        _ = try? subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))

        #expect(audit.entries.count == 1,
                "rate-limited requests never reached the cleaner and must not be audited")
    }
}

// MARK: - Test capture helpers

private final class AuditCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditEntry] = []

    func record(_ entry: AuditEntry) throws {
        lock.lock(); storage.append(entry); lock.unlock()
    }

    var entries: [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
