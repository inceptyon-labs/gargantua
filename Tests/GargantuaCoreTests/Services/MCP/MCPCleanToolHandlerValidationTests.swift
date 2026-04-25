import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP clean tool handler — validation and safety")
struct MCPCleanToolHandlerValidationTests {

    // MARK: Protected hard-reject

    @Test("any protected item in the resolved set rejects the whole request as invalidParams")
    func protectedHardReject() throws {
        let items = [
            MCPCleanTestFixtures.makeResult(id: "safe1", safety: .safe),
            MCPCleanTestFixtures.makeResult(id: "prot", safety: .protected_),
        ]
        let cache = MCPCleanTestFixtures.cacheWith(items)
        let cleanerCalled = MCPCleanTestFixtures.CapturedFlag()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("safe1"), .string("prot")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("protected"))
            #expect(message.contains("prot"))
        }
        #expect(cleanerCalled.value == false, "cleaner must not run when any protected item is present")
    }

    @Test("protected item rejection happens even in dry-run mode")
    func protectedRejectedInDryRun() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "p", safety: .protected_)])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("p")]),
                "confirm": .bool(true),
                "dry_run": .bool(true),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("protected"))
        }
    }

    // MARK: Unknown IDs

    @Test("unknown item_ids reject the request as invalidParams")
    func unknownIDsRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "known")])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("known"), .string("ghost")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("ghost"))
            #expect(message.contains("Unknown"))
        }
    }

    @Test("a fresh cache treats every id as unknown")
    func freshCacheAllUnknown() throws {
        let cache = MCPScanSessionCache()
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected.
        }
    }

    // MARK: Method validation

    @Test("unknown method value is rejected with invalidParams")
    func unknownMethodRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a")]),
                "method": .string("nuclear"),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("nuclear"))
        }
    }

    @Test("tool_native method is rejected via MCP even though CleanupEngine accepts it")
    func toolNativeRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a")]),
                "method": .string("tool_native"),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — clean schema advertises only trash|delete.
        }
    }

    // MARK: Confirm enforcement (type boundary)

    @Test("missing confirm is rejected with invalidParams")
    func missingConfirmRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a")]),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("confirm") || message.contains("Invalid"))
        }
    }

    @Test("confirm: false is rejected with invalidParams")
    func confirmFalseRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a")]),
                "confirm": .bool(false),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected.
        }
    }

    @Test("duplicate item_ids are rejected with invalidParams")
    func duplicateItemIDsRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let cleanerCalled = MCPCleanTestFixtures.CapturedFlag()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("a"), .string("a")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("a"))
            #expect(message.lowercased().contains("duplicate"))
        }
        #expect(cleanerCalled.value == false, "cleaner must not run on a duplicate-id request")
    }

    @Test("empty item_ids is rejected at decode")
    func emptyItemIDsRejected() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a")])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — MCPCleanInput rejects empty arrays at decode.
        }
    }
}
