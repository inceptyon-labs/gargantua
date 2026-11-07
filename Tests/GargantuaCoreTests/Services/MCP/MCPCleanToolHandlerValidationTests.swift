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

    // MARK: Review tier

    @Test("review items are rejected unless include_review is true")
    func reviewRequiresIncludeReview() throws {
        let cache = MCPCleanTestFixtures.cacheWith([
            MCPCleanTestFixtures.makeResult(id: "safe1"),
            MCPCleanTestFixtures.makeResult(id: "rev", safety: .review),
        ])
        let cleanerCalled = MCPCleanTestFixtures.CapturedFlag()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("safe1"), .string("rev")]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("include_review"))
            #expect(message.contains("rev"))
        }
        #expect(cleanerCalled.value == false, "cleaner must not run without include_review")
    }

    @Test("review items are never permanently deleted, even with include_review")
    func reviewRefusesDelete() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "rev", safety: .review)])
        let cleanerCalled = MCPCleanTestFixtures.CapturedFlag()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .delete)
        })
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("rev")]),
                "method": .string("delete"),
                "confirm": .bool(true),
                "include_review": .bool(true),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("Trash"))
            #expect(message.contains("rev"))
        }
        #expect(cleanerCalled.value == false, "cleaner must not run a delete that names a review item")
    }

    @Test("review items move to the Trash when include_review is true")
    func reviewTrashesWithIncludeReview() throws {
        let items = [MCPCleanTestFixtures.makeResult(id: "rev", safety: .review)]
        let cache = MCPCleanTestFixtures.cacheWith(items)
        let captured = MCPCleanTestFixtures.CapturedMethod()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { cleaned, method in
            captured.value = method
            return CleanupResult(
                itemResults: cleaned.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: method
            )
        })
        _ = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("rev")]),
            "confirm": .bool(true),
            "include_review": .bool(true),
        ]))
        #expect(captured.value == .trash)
    }

    @Test("dry runs preview review items without include_review")
    func dryRunPreviewsReviewWithoutIncludeReview() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "rev", safety: .review)])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("rev")]),
            "method": .string("delete"),
            "confirm": .bool(true),
            "dry_run": .bool(true),
        ]))
        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.perItem.map(\.id) == ["rev"])
    }

    @Test("cleaning the Trash itself requires method delete")
    func trashContainerRequiresDelete() throws {
        let trashPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "user_trash", path: trashPath)])
        let subject = MCPCleanTestFixtures.handler(cache: cache)
        do {
            _ = try subject.handle(MCPCleanTestFixtures.arguments([
                "item_ids": .array([.string("user_trash")]),
                "confirm": .bool(true),
                "dry_run": .bool(true),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("permanently"))
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
