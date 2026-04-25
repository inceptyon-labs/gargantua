import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP clean tool handler — execution, errors, and wire format")
struct MCPCleanToolHandlerExecutionTests {

    // MARK: Dry-run

    @Test("dry_run returns plan without invoking cleaner")
    func dryRunSkipsCleaner() throws {
        let items = [
            MCPCleanTestFixtures.makeResult(id: "a", size: 1_500_000),
            MCPCleanTestFixtures.makeResult(id: "b", size: 500_000),
        ]
        let cache = MCPCleanTestFixtures.cacheWith(items)
        let cleanerCalled = MCPCleanTestFixtures.CapturedFlag()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a"), .string("b")]),
            "confirm": .bool(true),
            "dry_run": .bool(true),
        ]))
        #expect(cleanerCalled.value == false, "dry-run must not invoke the cleaner")
        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.freed == "2.0 MB")
        #expect(output.perItem.allSatisfy { $0.outcome == "moved" })
        #expect(output.perItem[0].bytesFreed == 1_500_000)
    }

    @Test("dry_run summary text signals the plan-not-executed mode")
    func dryRunSummaryText() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a", size: 1_024)])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
            "dry_run": .bool(true),
        ]))
        guard case .text(let summary) = result.content.first else {
            Issue.record("first content block should be text")
            return
        }
        #expect(summary.contains("dry-run"))
    }

    // MARK: Partial failure

    @Test("cleaner-reported failures surface as per-item failed outcomes with reasons")
    func partialFailureSurfaces() throws {
        let items = [
            MCPCleanTestFixtures.makeResult(id: "ok", size: 1_000_000),
            MCPCleanTestFixtures.makeResult(id: "bad", size: 500_000),
        ]
        let cache = MCPCleanTestFixtures.cacheWith(items)
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { resolved, _ in
            CleanupResult(
                itemResults: [
                    CleanupItemResult(item: resolved[0], succeeded: true),
                    CleanupItemResult(item: resolved[1], succeeded: false, error: "disk full"),
                ],
                cleanupMethod: .trash
            )
        })
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("ok"), .string("bad")]),
            "confirm": .bool(true),
        ]))
        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.cleaned == 1)
        #expect(output.freed == "1.0 MB")
        #expect(output.perItem.count == 2)
        #expect(output.perItem[0].outcome == "moved")
        #expect(output.perItem[1].outcome == "failed")
        #expect(output.perItem[1].reason == "disk full")
        #expect(output.perItem[1].bytesFreed == nil)
    }

    // MARK: Cleaner error handling

    @Test("cleaner throwing MCPToolError.invalidParams rethrows for dispatcher")
    func cleanerRethrowsInvalidParams() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in
            throw MCPToolError.invalidParams("bad method")
        })
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad method")
        }
    }

    @Test("cleaner throwing a LocalizedError surfaces as tool-domain .failure")
    func cleanerLocalizedError() throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "engine exploded" } }
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in throw Boom() })
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Clean failed"))
        #expect(message.contains("engine exploded"))
    }

    @Test("cleaner throwing a plain Error does not leak its reflection")
    func cleanerGenericErrorSanitized() throws {
        struct SecretLeak: Error { let path = "/Users/victim/Library/Secrets" }
        let captured = MCPCleanTestFixtures.CapturedLog()
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { _, _ in throw SecretLeak() },
            auditIDGenerator: { MCPCleanTestFixtures.fixedAuditUUID },
            log: { captured.append($0) }
        )
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(!message.contains("SecretLeak"))
        #expect(!message.contains("/Users/victim"))
        #expect(captured.joined.contains("SecretLeak"))
    }

    // MARK: Wire format

    @Test("wire envelope uses snake_case keys matching the PRD contract")
    func wireKeysAreSnakeCase() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a", size: 1_024)])
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { items, _ in
            CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: .trash
            )
        })
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        let payload = try #require(result.structuredContent)
        guard case .object(let root) = payload else {
            Issue.record("payload must be an object")
            return
        }
        #expect(root["cleaned"] != nil)
        #expect(root["freed"] != nil)
        #expect(root["method"] != nil)
        #expect(root["audit_id"] != nil)
        #expect(root["per_item"] != nil)
        guard case .array(let perItem) = root["per_item"],
              case .object(let first) = perItem.first else {
            Issue.record("per_item should be a non-empty array of objects")
            return
        }
        #expect(first["id"] != nil)
        #expect(first["outcome"] != nil)
        #expect(first["bytes_freed"] != nil)
    }
}
