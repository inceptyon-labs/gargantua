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
    clientID: String? = nil
) -> MCPCleanToolHandler {
    MCPCleanToolHandler(
        sessionCache: cache,
        cleaner: cleaner,
        auditIDGenerator: { auditUUID },
        auditRecorder: auditRecorder,
        clientIDProvider: { clientID }
    )
}

@Suite("MCP clean tool handler — audit entry skipped")
struct MCPCleanToolHandlerAuditSkipTests {

    @Test("dry-run does not write an audit entry")
    func noAuditOnDryRun() throws {
        let cache = cacheWith([makeResult(id: "a")])
        let audit = AuditCapture()
        let subject = makeHandler(
            cache: cache,
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )
        _ = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
            "dry_run": .bool(true),
        ]))
        #expect(audit.entries.isEmpty)
    }

    @Test("validation rejections (protected, unknown, duplicate, bad method) do not write audit entries")
    func noAuditOnValidationRejection() throws {
        let audit = AuditCapture()

        let protectedHandler = makeHandler(
            cache: cacheWith([makeResult(id: "p", safety: .protected_)]),
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )
        _ = try? protectedHandler.handle(arguments([
            "item_ids": .array([.string("p")]),
            "confirm": .bool(true),
        ]))

        let unknownHandler = makeHandler(
            cache: cacheWith([makeResult(id: "k")]),
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )
        _ = try? unknownHandler.handle(arguments([
            "item_ids": .array([.string("missing")]),
            "confirm": .bool(true),
        ]))

        let dupHandler = makeHandler(
            cache: cacheWith([makeResult(id: "d")]),
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )
        _ = try? dupHandler.handle(arguments([
            "item_ids": .array([.string("d"), .string("d")]),
            "confirm": .bool(true),
        ]))

        let badMethodHandler = makeHandler(
            cache: cacheWith([makeResult(id: "m")]),
            auditRecorder: { try audit.record($0) },
            clientID: "claude-code"
        )
        _ = try? badMethodHandler.handle(arguments([
            "item_ids": .array([.string("m")]),
            "method": .string("nuclear"),
            "confirm": .bool(true),
        ]))

        #expect(audit.entries.isEmpty,
                "validation rejections must not create audit entries — attempts never reached the cleaner")
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
