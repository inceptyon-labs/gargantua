import Foundation
import Testing
@testable import GargantuaCore

/// The clean rate limit used to shard on the client's self-declared
/// `clientInfo.name`. `initialize` is an ordinary dispatchable method with
/// last-initialize-wins semantics, so a client could rename itself between
/// cleans and win a fresh budget without even reconnecting. The shard key now
/// comes from a separate provider that production feeds with the connection id.
@Suite("MCP clean rate-limit shard key")
struct MCPCleanRateLimitShardKeyTests {

    private static func makeResult(id: String) -> ScanResult {
        ScanResult(
            id: id,
            name: "name-\(id)",
            path: "/tmp/\(id)",
            size: 1_000,
            safety: .safe,
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

    private func cleanArguments() -> MCPToolArguments {
        MCPToolArguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ])
    }

    /// Mutable box the `@Sendable` provider closures write through.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test("renaming the client does not reset the budget when the shard key is stable")
    func renameDoesNotResetBudget() throws {
        let declaredName = Box("claude-code")
        let subject = MCPCleanToolHandler(
            sessionCache: Self.cacheWith([Self.makeResult(id: "a")]),
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            rateLimiter: MCPRateLimiter(window: 60, maxOps: 1),
            clientIDProvider: { declaredName.value },
            rateLimitKeyProvider: { "stdio" }
        )

        _ = try subject.handle(cleanArguments())

        // The client re-`initialize`s under a different name; the connection is
        // the same, so the budget must be too.
        declaredName.value = "definitely-a-different-client"

        #expect(throws: MCPToolError.self) {
            _ = try subject.handle(self.cleanArguments())
        }
    }

    @Test("a different connection gets its own budget")
    func separateConnectionsGetSeparateBudgets() throws {
        let connection = Box("sse(session-1)")
        let subject = MCPCleanToolHandler(
            sessionCache: Self.cacheWith([Self.makeResult(id: "a")]),
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            rateLimiter: MCPRateLimiter(window: 60, maxOps: 1),
            clientIDProvider: { "claude-code" },
            rateLimitKeyProvider: { connection.value }
        )

        _ = try subject.handle(cleanArguments())
        connection.value = "sse(session-2)"
        _ = try subject.handle(cleanArguments())
    }

    @Test("without a key provider the declared name still shards the budget")
    func fallsBackToClientID() throws {
        let subject = MCPCleanToolHandler(
            sessionCache: Self.cacheWith([Self.makeResult(id: "a")]),
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            rateLimiter: MCPRateLimiter(window: 60, maxOps: 1),
            clientIDProvider: { "claude-code" }
        )

        _ = try subject.handle(cleanArguments())
        #expect(throws: MCPToolError.self) {
            _ = try subject.handle(self.cleanArguments())
        }
    }
}

/// A consent gate that cannot show a prompt must refuse, not silently proceed.
@Suite("MCP clean consent fails closed")
struct MCPCleanConsentFailClosedTests {

    @Test("the refusing service reports a refusal, not a user cancellation")
    func refusingServiceRefuses() {
        let decision = RefusingMCPCleanNotificationService().request(
            items: [],
            method: .trash,
            clientID: "claude-code"
        )

        guard case .refused(let reason) = decision else {
            Issue.record("expected .refused, got \(decision)")
            return
        }
        #expect(reason.contains("--allow-unattended-clean"))
    }

    @Test("the no-op service still proceeds, for the explicit opt-out path")
    func noopServiceProceeds() {
        let decision = NoopMCPCleanNotificationService().request(
            items: [],
            method: .trash,
            clientID: "claude-code"
        )
        #expect(decision == .proceed)
    }
}
