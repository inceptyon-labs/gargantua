import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP clean tool handler")
struct MCPCleanToolHandlerTests {

    // MARK: Fixtures

    // Deterministic audit UUID for wire-assertion. `uuidString` always
    // returns uppercase, so the wire-form string we expect is the uppercase
    // form; tests that decode it back through UUID round-trip freely.
    private static let fixedAuditUUID = UUID(uuidString: "00000000-0000-0000-0000-00000000AF01")!
    private static var fixedAuditID: String { fixedAuditUUID.uuidString }

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static func makeResult(
        id: String,
        size: Int64 = 1_000_000,
        safety: SafetyLevel = .safe,
        path: String? = nil,
        name: String? = nil
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: name ?? "name-\(id)",
            path: path ?? "/tmp/\(id)",
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

    /// Ergonomic arguments builder mirroring what the dispatcher would pass in.
    private func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
        MCPToolArguments(dict)
    }

    private func handler(
        cache: MCPScanSessionCache,
        cleaner: @escaping MCPCleanToolHandler.Cleaner = { _, _ in
            CleanupResult(itemResults: [], cleanupMethod: .trash)
        },
        auditUUID: UUID = fixedAuditUUID,
        auditRecorder: MCPCleanToolHandler.AuditRecorder? = nil,
        rateLimiter: MCPRateLimiter? = nil,
        clientID: String? = nil,
        log: MCPDispatcherLog? = nil
    ) -> MCPCleanToolHandler {
        MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: cleaner,
            auditIDGenerator: { auditUUID },
            auditRecorder: auditRecorder,
            rateLimiter: rateLimiter,
            clientIDProvider: { clientID },
            log: log
        )
    }

    private static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPCleanOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPCleanOutput.self, from: data)
    }

    private static let defaultConfirmArg: [String: MCPJSONAny] = ["confirm": .bool(true)]

    // MARK: Happy path

    @Test("cleans resolved items via the injected cleaner and reports per-item moved outcomes")
    func happyPathMovedOutcomes() throws {
        let items = [
            Self.makeResult(id: "a", size: 1_000_000),
            Self.makeResult(id: "b", size: 2_000_000),
        ]
        let cache = Self.cacheWith(items)
        let cleanerCallCount = CapturedCounter()
        let subject = handler(
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

        let result = try subject.handle(arguments([
            "item_ids": .array([.string("a"), .string("b")]),
            "confirm": .bool(true),
        ]))

        #expect(result.isError == false)
        #expect(cleanerCallCount.value == 1)

        let output = try Self.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.freed == "3.0 MB")
        #expect(output.method == "trash")
        #expect(output.auditID == Self.fixedAuditID)
        #expect(output.perItem.count == 2)
        #expect(output.perItem[0].outcome == "moved")
        #expect(output.perItem[0].bytesFreed == 1_000_000)
        #expect(output.perItem[0].reason == nil)
        #expect(output.perItem[1].outcome == "moved")
        #expect(output.perItem[1].bytesFreed == 2_000_000)
    }

    @Test("method defaults to trash when omitted from the payload")
    func methodDefaultsToTrash() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a", size: 100)])
        let received = CapturedMethod()
        let subject = handler(cache: cache, cleaner: { items, method in
            received.value = method
            return CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: method
            )
        })
        _ = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "confirm": .bool(true),
        ]))
        #expect(received.value == .trash)
    }

    @Test("method delete routes to CleanupMethod.delete")
    func deleteMethod() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a", size: 100)])
        let received = CapturedMethod()
        let subject = handler(cache: cache, cleaner: { items, method in
            received.value = method
            return CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: method
            )
        })
        let result = try subject.handle(arguments([
            "item_ids": .array([.string("a")]),
            "method": .string("delete"),
            "confirm": .bool(true),
        ]))
        #expect(received.value == .delete)
        let output = try Self.decodeOutput(result)
        #expect(output.method == "delete")
    }

    @Test("review-tier items are cleaned like safe items when confirm is true")
    func reviewItemsAccepted() throws {
        let items = [
            Self.makeResult(id: "s", size: 1_000, safety: .safe),
            Self.makeResult(id: "r", size: 2_000, safety: .review),
        ]
        let cache = Self.cacheWith(items)
        let subject = handler(cache: cache, cleaner: { resolved, _ in
            CleanupResult(
                itemResults: resolved.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: .trash
            )
        })
        let result = try subject.handle(arguments([
            "item_ids": .array([.string("s"), .string("r")]),
            "confirm": .bool(true),
        ]))
        let output = try Self.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.perItem.allSatisfy { $0.outcome == "moved" })
    }

    // MARK: Protected hard-reject

    @Test("any protected item in the resolved set rejects the whole request as invalidParams")
    func protectedHardReject() throws {
        let items = [
            Self.makeResult(id: "safe1", safety: .safe),
            Self.makeResult(id: "prot", safety: .protected_),
        ]
        let cache = Self.cacheWith(items)
        let cleanerCalled = CapturedFlag()
        let subject = handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "p", safety: .protected_)])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "known")])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
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
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
                "item_ids": .array([.string("a")]),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("confirm") || message.contains("Invalid"))
        }
    }

    @Test("confirm: false is rejected with invalidParams")
    func confirmFalseRejected() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let cleanerCalled = CapturedFlag()
        let subject = handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache)
        do {
            _ = try subject.handle(arguments([
                "item_ids": .array([]),
                "confirm": .bool(true),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — MCPCleanInput rejects empty arrays at decode.
        }
    }

    // MARK: Dry-run

    @Test("dry_run returns plan without invoking cleaner")
    func dryRunSkipsCleaner() throws {
        let items = [
            Self.makeResult(id: "a", size: 1_500_000),
            Self.makeResult(id: "b", size: 500_000),
        ]
        let cache = Self.cacheWith(items)
        let cleanerCalled = CapturedFlag()
        let subject = handler(cache: cache, cleaner: { _, _ in
            cleanerCalled.value = true
            return CleanupResult(itemResults: [], cleanupMethod: .trash)
        })
        let result = try subject.handle(arguments([
            "item_ids": .array([.string("a"), .string("b")]),
            "confirm": .bool(true),
            "dry_run": .bool(true),
        ]))
        #expect(cleanerCalled.value == false, "dry-run must not invoke the cleaner")
        let output = try Self.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.freed == "2.0 MB")
        #expect(output.perItem.allSatisfy { $0.outcome == "moved" })
        #expect(output.perItem[0].bytesFreed == 1_500_000)
    }

    @Test("dry_run summary text signals the plan-not-executed mode")
    func dryRunSummaryText() throws {
        let cache = Self.cacheWith([Self.makeResult(id: "a", size: 1_024)])
        let subject = handler(cache: cache)
        let result = try subject.handle(arguments([
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
            Self.makeResult(id: "ok", size: 1_000_000),
            Self.makeResult(id: "bad", size: 500_000),
        ]
        let cache = Self.cacheWith(items)
        let subject = handler(cache: cache, cleaner: { resolved, _ in
            CleanupResult(
                itemResults: [
                    CleanupItemResult(item: resolved[0], succeeded: true),
                    CleanupItemResult(item: resolved[1], succeeded: false, error: "disk full"),
                ],
                cleanupMethod: .trash
            )
        })
        let result = try subject.handle(arguments([
            "item_ids": .array([.string("ok"), .string("bad")]),
            "confirm": .bool(true),
        ]))
        let output = try Self.decodeOutput(result)
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache, cleaner: { _, _ in
            throw MCPToolError.invalidParams("bad method")
        })
        do {
            _ = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = handler(cache: cache, cleaner: { _, _ in throw Boom() })
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
        #expect(message.contains("engine exploded"))
    }

    @Test("cleaner throwing a plain Error does not leak its reflection")
    func cleanerGenericErrorSanitized() throws {
        struct SecretLeak: Error { let path = "/Users/victim/Library/Secrets" }
        let captured = CapturedLog()
        let cache = Self.cacheWith([Self.makeResult(id: "a")])
        let subject = MCPCleanToolHandler(
            sessionCache: cache,
            cleaner: { _, _ in throw SecretLeak() },
            auditIDGenerator: { Self.fixedAuditUUID },
            log: { captured.append($0) }
        )
        let result = try subject.handle(arguments([
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
        let cache = Self.cacheWith([Self.makeResult(id: "a", size: 1_024)])
        let subject = handler(cache: cache, cleaner: { items, _ in
            CleanupResult(
                itemResults: items.map { CleanupItemResult(item: $0, succeeded: true) },
                cleanupMethod: .trash
            )
        })
        let result = try subject.handle(arguments([
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

    // MARK: Cache integration

    @Test("a scan followed by clean resolves IDs via the shared session cache")
    func scanThenCleanViaSharedCache() throws {
        let cache = MCPScanSessionCache()
        let scanResults = [
            Self.makeResult(id: "scan-a", size: 100_000),
            Self.makeResult(id: "scan-b", size: 200_000),
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
            auditIDGenerator: { Self.fixedAuditUUID }
        )
        let result = try cleanHandler.handle(MCPToolArguments([
            "item_ids": .array([.string("scan-a"), .string("scan-b")]),
            "confirm": .bool(true),
        ]))
        let output = try Self.decodeOutput(result)
        #expect(output.cleaned == 2)
        #expect(output.freed == "300 KB")
    }

    @Test("a fresh scan invalidates IDs from a prior scan (last-scan-wins)")
    func priorScanIDsInvalidated() throws {
        let cache = MCPScanSessionCache()
        let scanHandler = MCPScanToolHandler(
            scanner: { _ in [Self.makeResult(id: "first")] },
            profileResolver: { _ in .light },
            sessionCache: cache
        )
        _ = try scanHandler.handle(MCPToolArguments(["dry_run": .bool(true)]))
        // Second scan replaces the cache.
        let scanHandler2 = MCPScanToolHandler(
            scanner: { _ in [Self.makeResult(id: "second")] },
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
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo, tools: tools)

        let cache = Self.cacheWith([Self.makeResult(id: "dispatched", size: 4_096)])
        let subject = handler(cache: cache, cleaner: { items, _ in
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
            serverInfo: Self.serverInfo,
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
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo, tools: tools)
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

// MARK: - Test capture helpers

private final class CapturedFlag: @unchecked Sendable {
    var value: Bool = false
}

private final class CapturedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0
    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private final class CapturedMethod: @unchecked Sendable {
    var value: CleanupMethod?
}

private final class CapturedLog: @unchecked Sendable {
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
