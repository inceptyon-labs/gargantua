import Testing
import Foundation
@testable import GargantuaCore

private let fixedAuditUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000AF01")!

private func makeResult(
    id: String,
    size: Int64 = 1_000_000,
    safety: SafetyLevel = .safe,
    path: String? = nil
) -> ScanResult {
    ScanResult(
        id: id,
        name: "name-\(id)",
        path: path ?? "/tmp/\(id)",
        size: size,
        safety: safety,
        confidence: 95,
        explanation: "test",
        source: SourceAttribution(name: "TestApp"),
        category: "browser_cache"
    )
}

private func cacheWith(_ items: [ScanResult]) -> MCPScanSessionCache {
    let cache = MCPScanSessionCache()
    cache.replace(with: items)
    return cache
}

private func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
    MCPToolArguments(dict)
}

private func makeHandler(
    cache: MCPScanSessionCache,
    cleaner: @escaping MCPCleanToolHandler.Cleaner = { _, _ in
        CleanupResult(itemResults: [], cleanupMethod: .trash)
    },
    auditUUID: UUID = fixedAuditUUID,
    auditRecorder: MCPCleanToolHandler.AuditRecorder? = nil,
    clientID: String? = nil,
    log: MCPDispatcherLog? = nil
) -> MCPCleanToolHandler {
    MCPCleanToolHandler(
        sessionCache: cache,
        cleaner: cleaner,
        auditIDGenerator: { auditUUID },
        auditRecorder: auditRecorder,
        clientIDProvider: { clientID },
        log: log
    )
}

private func decodeOutput(_ result: MCPToolCallResult) throws -> MCPCleanOutput {
    let payload = try #require(result.structuredContent, "structured content missing")
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(MCPCleanOutput.self, from: data)
}

@Suite("MCP clean tool handler — audit entry written")
struct MCPCleanToolHandlerAuditWriteTests {

    // MARK: Happy path

    @Test("a successful clean writes an audit entry stamped with transport + client id")
    func auditEntryShapeOnSuccess() throws {
        let items = [
            makeResult(id: "a", size: 1_000),
            makeResult(id: "b", size: 2_000, safety: .review),
        ]
        let cache = cacheWith(items)
        let audit = AuditCapture()
        let subject = makeHandler(
            cache: cache,
            cleaner: { resolved, method in
                CleanupResult(
                    itemResults: resolved.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: method
                )
            },
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )

        _ = try subject.handle(arguments([
            "item_ids": .array([.string("a"), .string("b")]),
            "confirm": .bool(true),
        ]))

        let entry = try #require(audit.entries.first, "expected exactly one audit entry")
        #expect(audit.entries.count == 1)
        #expect(entry.transport == "mcp")
        #expect(entry.clientID == "claude-code")
        #expect(entry.command == "clean")
        #expect(entry.tool == "native")
        #expect(entry.confirmationMethod == .mcp)
        #expect(entry.cleanupMethod == .trash)
        #expect(entry.bytesFreed == 3_000)
        #expect(entry.safetyLevel == .review, "highest safety in the set should be recorded")
        #expect(entry.files.map(\.path) == ["/tmp/a", "/tmp/b"])
    }

    @Test("audit entry UUID matches the audit_id emitted on the wire")
    func auditIDRoundTrips() throws {
        let cache = cacheWith([makeResult(id: "a", size: 42)])
        let audit = AuditCapture()
        let fixed = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let subject = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            auditIDGenerator: { fixed },
            auditRecorder: { try audit.record($0) },
            clientIDProvider: { "claude-code" }
        )

        let result = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))

        let output = try decodeOutput(result)
        #expect(output.auditID == fixed.uuidString)
        #expect(audit.entries.first?.id == fixed)
    }

    // MARK: Cleaner-failure path still writes audit

    @Test("cleaner LocalizedError path still writes an audit entry")
    func auditEntryOnLocalizedFailure() throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "kaboom" } }
        let cache = cacheWith([makeResult(id: "a", size: 1_000)])
        let audit = AuditCapture()
        let subject = makeHandler(
            cache: cache,
            cleaner: { _, _ in throw Boom() },
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )

        let result = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))

        #expect(result.isError == true)
        let entry = try #require(audit.entries.first)
        #expect(entry.clientID == "claude-code")
        #expect(entry.bytesFreed == 0, "no bytes freed on failure")
        #expect(entry.cleanupMethod == .trash, "falls back to requested method on failure")
        #expect(entry.files.map(\.path) == ["/tmp/a"])
    }

    @Test("cleaner MCPToolError path still writes an audit entry before rethrowing")
    func auditEntryOnMCPToolError() throws {
        let cache = cacheWith([makeResult(id: "a")])
        let audit = AuditCapture()
        let subject = makeHandler(
            cache: cache,
            cleaner: { _, _ in throw MCPToolError.invalidParams("cleaner rejected") },
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )

        do {
            _ = try subject.handle(arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have rethrown invalidParams")
        } catch MCPToolError.invalidParams {
            // expected
        }
        #expect(audit.entries.count == 1)
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
