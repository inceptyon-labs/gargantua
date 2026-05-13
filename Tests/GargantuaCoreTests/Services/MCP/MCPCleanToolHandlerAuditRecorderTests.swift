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

@Suite("MCP clean tool handler — audit recorder robustness")
struct MCPCleanToolHandlerAuditRecorderTests {

    @Test("client ID falls back to 'unknown' sentinel when provider returns nil")
    func unknownClientSentinel() throws {
        let cache = cacheWith([makeResult(id: "a")])
        let audit = AuditCapture()
        let subject = makeHandler(
            cache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            auditRecorder: { try audit.record($0) },
            clientID: nil
        )

        _ = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(audit.entries.first?.clientID == MCPCleanToolHandler.unknownClientSentinel)
    }

    @Test("audit recorder failure on successful clean fails loud with internalError")
    func auditRecorderFailureOnSuccessIsFailLoud() throws {
        struct RecordBoom: Error, LocalizedError { var errorDescription: String? { "audit down" } }
        let cache = cacheWith([makeResult(id: "a", size: 5)])
        let captured = LogCapture()
        let subject = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            auditIDGenerator: { fixedAuditUUID },
            auditRecorder: { _ in throw RecordBoom() },
            clientIDProvider: { "claude-code" },
            log: { captured.append($0) }
        )

        do {
            _ = try subject.handle(arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("successful clean with failing audit must throw internalError")
        } catch MCPToolError.internalError(let message) {
            #expect(message.lowercased().contains("audit"))
            #expect(message.lowercased().contains("incomplete") || message.lowercased().contains("investigate"))
        }
        #expect(captured.joined.contains("audit record failed"))
    }

    @Test("audit recorder failure on cleaner failure path is best-effort — primary error surfaces")
    func auditRecorderFailureOnCleanerFailureIsBestEffort() throws {
        struct CleanerBoom: Error, LocalizedError { var errorDescription: String? { "cleaner exploded" } }
        struct RecordBoom: Error {}
        let cache = cacheWith([makeResult(id: "a", size: 5)])
        let captured = LogCapture()
        let subject = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { _, _ in throw CleanerBoom() },
            auditIDGenerator: { fixedAuditUUID },
            auditRecorder: { _ in throw RecordBoom() },
            clientIDProvider: { "claude-code" },
            log: { captured.append($0) }
        )

        // Primary failure is the cleaner exploding; secondary audit write
        // failure must not hide it.
        let result = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Clean failed"))
        #expect(message.contains("cleaner exploded"))
        #expect(captured.joined.contains("audit record failed during error path"))
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

private final class LogCapture: @unchecked Sendable {
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
