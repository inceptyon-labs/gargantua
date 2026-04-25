import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP clean tool handler")
struct MCPCleanToolHandlerTests {

    // MARK: Happy path

    @Test("cleans resolved items via the injected cleaner and reports per-item moved outcomes")
    func happyPathMovedOutcomes() throws {
        let items = [
            MCPCleanTestFixtures.makeResult(id: "a", size: 1_000_000),
            MCPCleanTestFixtures.makeResult(id: "b", size: 2_000_000),
        ]
        let cache = MCPCleanTestFixtures.cacheWith(items)
        let cleanerCallCount = MCPCleanTestFixtures.CapturedCounter()
        let subject = MCPCleanTestFixtures.handler(
            cache: cache,
            cleaner: { resolved, method in
                cleanerCallCount.increment()
                #expect(method == .trash)
                #expect(resolved.map(\.id) == ["a", "b"])
                return CleanupResult(
                    itemResults: resolved.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            }
        )

        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a"), .string("b")]),
            "confirm": .bool(true),
        ]))

        #expect(result.isError == false)
        #expect(cleanerCallCount.value == 1)

        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.freed == "3.0 MB")
        #expect(output.method == "trash")
        #expect(output.auditID == MCPCleanTestFixtures.fixedAuditID)
        #expect(output.perItem.count == 2)
        #expect(output.perItem[0].outcome == "moved")
        #expect(output.perItem[0].bytesFreed == 1_000_000)
        #expect(output.perItem[0].reason == nil)
        #expect(output.perItem[1].outcome == "moved")
        #expect(output.perItem[1].bytesFreed == 2_000_000)
    }

    @Test("method defaults to trash when omitted from the payload")
    func methodDefaultsToTrash() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a", size: 100)])
        let received = MCPCleanTestFixtures.CapturedMethod()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { items, method in
            received.value = method
            return CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: method
            )
        })
        _ = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(received.value == .trash)
    }

    @Test("method delete routes to CleanupMethod.delete")
    func deleteMethod() throws {
        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "a", size: 100)])
        let received = MCPCleanTestFixtures.CapturedMethod()
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { items, method in
            received.value = method
            return CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: method
            )
        })
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("a")]),
            "method": .string("delete"),
            "confirm": .bool(true),
        ]))
        #expect(received.value == .delete)
        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.method == "delete")
    }

    @Test("review-tier items are cleaned like safe items when confirm is true")
    func reviewItemsAccepted() throws {
        let items = [
            MCPCleanTestFixtures.makeResult(id: "s", size: 1_000, safety: .safe),
            MCPCleanTestFixtures.makeResult(id: "r", size: 2_000, safety: .review),
        ]
        let cache = MCPCleanTestFixtures.cacheWith(items)
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { resolved, _ in
            CleanupResult(
                itemResults: resolved.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: .trash
            )
        })
        let result = try subject.handle(MCPCleanTestFixtures.arguments([
            "item_ids": .array([.string("s"), .string("r")]),
            "confirm": .bool(true),
        ]))
        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.perItem.allSatisfy { $0.outcome == "moved" })
    }

    // MARK: Cache integration

    @Test("a scan followed by clean resolves IDs via the shared session cache")
    func scanThenCleanViaSharedCache() throws {
        let cache = MCPScanSessionCache()
        let scanResults = [
            MCPCleanTestFixtures.makeResult(id: "scan-a", size: 100_000),
            MCPCleanTestFixtures.makeResult(id: "scan-b", size: 200_000),
        ]
        let scanHandler = MCPScanToolHandler(
            scanner: { _ in scanResults },
            profileResolver: { _ in .light },
            sessionCache: cache
        )
        _ = try scanHandler.handle(MCPToolArguments(["dry_run": .bool(true)]))

        #expect(cache.count == 2)
        #expect(cache.lookup(id: "scan-a")?.size == 100_000)

        let cleanHandler = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            },
            auditIDGenerator: { MCPCleanTestFixtures.fixedAuditUUID }
        )
        let result = try cleanHandler.handle(MCPToolArguments([
            "item_ids": .array([.string("scan-a"), .string("scan-b")]),
            "confirm": .bool(true),
        ]))
        let output = try MCPCleanTestFixtures.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.freed == "300 KB")
    }

    @Test("a fresh scan invalidates IDs from a prior scan (last-scan-wins)")
    func priorScanIDsInvalidated() throws {
        let cache = MCPScanSessionCache()
        let scanHandler = MCPScanToolHandler(
            scanner: { _ in [MCPCleanTestFixtures.makeResult(id: "first")] },
            profileResolver: { _ in .light },
            sessionCache: cache
        )
        _ = try scanHandler.handle(MCPToolArguments(["dry_run": .bool(true)]))
        // Second scan replaces the cache.
        let scanHandler2 = MCPScanToolHandler(
            scanner: { _ in [MCPCleanTestFixtures.makeResult(id: "second")] },
            profileResolver: { _ in .light },
            sessionCache: cache
        )
        _ = try scanHandler2.handle(MCPToolArguments(["dry_run": .bool(true)]))

        let cleanHandler = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { items, _ in
                CleanupResult(
                    itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                    cleanupMethod: .trash
                )
            }
        )
        do {
            _ = try cleanHandler.handle(MCPToolArguments([
                "item_ids": .array([.string("first")]),
                "confirm": .bool(true),
            ]))
            Issue.record("clean should have rejected stale id from prior scan")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("first"))
        }
    }

    // MARK: Dispatcher integration

    @Test("registering clean handler with a Phase 3-capable dispatcher routes tools/call to it")
    func dispatcherIntegrationPhase3() throws {
        let tools = MCPPhase2Tools.all + MCPPhase3Tools.all
        let dispatcher = MCPRequestDispatcher(serverInfo: MCPCleanTestFixtures.serverInfo, tools: tools)

        let cache = MCPCleanTestFixtures.cacheWith([MCPCleanTestFixtures.makeResult(id: "dispatched", size: 4_096)])
        let subject = MCPCleanTestFixtures.handler(cache: cache, cleaner: { items, _ in
            CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: .trash
            )
        })
        dispatcher.register(tool: .clean, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(42),
            method: "tools/call",
            params: .object([
                "name": .string("clean"),
                "arguments": .object([
                    "item_ids": .array([.string("dispatched")]),
                    "confirm": .bool(true),
                ]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)

        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["structuredContent"] != nil)
        #expect(envelope["isError"] == nil)
    }

    @Test("Phase 2-only dispatcher does not expose clean via tools/list")
    func phase2OnlyHidesCleanFromToolsList() throws {
        let dispatcher = MCPRequestDispatcher(
            serverInfo: MCPCleanTestFixtures.serverInfo,
            tools: MCPPhase2Tools.all
        )
        let request = MCPRequest(id: .int(1), method: "tools/list", params: nil)
        let response = try #require(dispatcher.dispatch(request))
        guard case .object(let envelope) = response.result,
              case .array(let tools) = envelope["tools"] else {
            Issue.record("tools/list should return an object with a tools array")
            return
        }
        let names: [String] = tools.compactMap { entry in
            guard case .object(let fields) = entry,
                  case .string(let name) = fields["name"] else { return nil }
            return name
        }
        #expect(!names.contains("clean"))
    }

    @Test("Phase 3 dispatcher advertises clean in tools/list")
    func phase3ExposesCleanInToolsList() throws {
        let tools = MCPPhase2Tools.all + MCPPhase3Tools.all
        let dispatcher = MCPRequestDispatcher(serverInfo: MCPCleanTestFixtures.serverInfo, tools: tools)
        let request = MCPRequest(id: .int(1), method: "tools/list", params: nil)
        let response = try #require(dispatcher.dispatch(request))
        guard case .object(let envelope) = response.result,
              case .array(let entries) = envelope["tools"] else {
            Issue.record("tools/list should return an object with a tools array")
            return
        }
        let names: [String] = entries.compactMap { entry in
            guard case .object(let fields) = entry,
                  case .string(let name) = fields["name"] else { return nil }
            return name
        }
        #expect(names.contains("clean"))
    }
}
