import Testing
import Foundation
@testable import GargantuaCore

// End-to-end coverage of the dispatcher → MCPCleanToolHandler seam: the
// most likely place for attribution regressions is the wiring between
// `MCPRequestDispatcher.currentClientIdentity()` and the handler's
// `ClientIDProvider`. These tests walk the full handshake + tools/call
// path so a refactor on either side surfaces here.
@Suite("MCP clean tool handler — integration")
struct MCPCleanToolHandlerIntegrationTests {

    // MARK: Fixtures

    private static func makeResult(id: String, size: Int64 = 1_000) -> ScanResult {
        ScanResult(
            id: id,
            name: "name-\(id)",
            path: "/tmp/\(id)",
            size: size,
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

    private static func buildDispatcher(
        cache: MCPScanSessionCache,
        audit: AuditCapture
    ) -> MCPRequestDispatcher {
        let tools = MCPPhase2Tools.all + MCPPhase3Tools.all
        let dispatcher = MCPRequestDispatcher(
            serverInfo: MCPServerInfo(name: "gargantua", version: "0.0.1"),
            tools: tools
        )
        // Production wiring shape (Task 4 will plug this into main.swift):
        // handler pulls the captured identity from the dispatcher on every
        // call rather than taking a frozen reference.
        let handlerSubject = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            auditRecorder: { try audit.record($0) },
            clientIDProvider: { dispatcher.currentClientIdentity()?.name }
        )
        dispatcher.register(tool: .clean, handler: handlerSubject.toolHandler)
        return dispatcher
    }

    // MARK: Tests

    @Test("initialize(clientInfo) → tools/call clean → audit carries that clientInfo.name")
    func dispatcherToHandlerAttributionEndToEnd() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "e2e", size: 12_345)])
        let audit = AuditCapture()
        let dispatcher = Self.buildDispatcher(cache: cache, audit: audit)

        // Step 1: initialize with a named client.
        let initResponse = dispatcher.dispatch(MCPRequest(
            id: .int(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("claude-code-e2e"),
                    "version": .string("1.2.3"),
                ]),
            ])
        ))
        #expect(initResponse?.error == nil)

        // Step 2: tools/call clean.
        let cleanResponse = dispatcher.dispatch(MCPRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("clean"),
                "arguments": .object([
                    "item_ids": .array([.string("e2e")]),
                    "confirm": .bool(true),
                ]),
            ])
        ))
        #expect(cleanResponse?.error == nil)

        let entry = try #require(audit.entries.first)
        #expect(entry.clientID == "claude-code-e2e")
        #expect(entry.transport == "mcp")
        #expect(entry.bytesFreed == 12_345)
    }

    @Test("clean arriving before initialize audits under the 'unknown' sentinel")
    func preInitCleanUsesUnknownSentinel() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "early", size: 1)])
        let audit = AuditCapture()
        let dispatcher = Self.buildDispatcher(cache: cache, audit: audit)

        let response = dispatcher.dispatch(MCPRequest(
            id: .int(1),
            method: "tools/call",
            params: .object([
                "name": .string("clean"),
                "arguments": .object([
                    "item_ids": .array([.string("early")]),
                    "confirm": .bool(true),
                ]),
            ])
        ))
        #expect(response?.error == nil)
        #expect(audit.entries.first?.clientID == MCPCleanToolHandler.unknownClientSentinel)
    }

    @Test("re-initialize with blank name audits under the 'unknown' sentinel")
    func reinitializeWithBlankNameResetsAttribution() throws {
        let cache = Self.cacheWith([
            Self.makeResult(id: "first", size: 1),
            Self.makeResult(id: "second", size: 2),
        ])
        let audit = AuditCapture()
        let dispatcher = Self.buildDispatcher(cache: cache, audit: audit)

        // Initial handshake: real client.
        _ = dispatcher.dispatch(MCPRequest(
            id: .int(1),
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("real-client"),
                ]),
            ])
        ))

        // Second handshake: blank name. Must clear the prior identity so
        // a rogue client cannot inherit "real-client"'s attribution by
        // sending a blank name on a follow-up initialize.
        _ = dispatcher.dispatch(MCPRequest(
            id: .int(2),
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("   "),
                ]),
            ])
        ))

        _ = dispatcher.dispatch(MCPRequest(
            id: .int(3),
            method: "tools/call",
            params: .object([
                "name": .string("clean"),
                "arguments": .object([
                    "item_ids": .array([.string("first")]),
                    "confirm": .bool(true),
                ]),
            ])
        ))

        let entry = try #require(audit.entries.first)
        #expect(entry.clientID == MCPCleanToolHandler.unknownClientSentinel,
                "blank-name re-init must not inherit prior client attribution")
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
