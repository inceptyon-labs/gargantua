import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP scan tool handler")
struct MCPScanToolHandlerTests {

    // MARK: Fixtures

    private static let fixedDate = Date(timeIntervalSince1970: 1_744_819_200) // 2025-04-16 16:00:00 UTC

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static func makeResult(
        id: String,
        size: Int64,
        safety: SafetyLevel,
        category: String = "browser_cache",
        path: String? = nil,
        name: String = "Test Item",
        source: String = "TestApp",
        confidence: Int = 95,
        explanation: String = "test explanation",
        lastAccessed: Date? = fixedDate
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: name,
            path: path ?? "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: SourceAttribution(name: source),
            lastAccessed: lastAccessed,
            category: category
        )
    }

    private func handler(
        scanner: @escaping MCPScanToolHandler.Scanner,
        resolver: @escaping MCPScanToolHandler.ProfileResolver = { _ in .light }
    ) -> MCPScanToolHandler {
        MCPScanToolHandler(scanner: scanner, profileResolver: resolver)
    }

    /// Ergonomic arguments builder that round-trips through JSON so the
    /// handler sees exactly what a dispatcher-routed call would see.
    private func arguments(_ dict: [String: MCPJSONAny]) -> MCPToolArguments {
        MCPToolArguments(dict)
    }

    /// Dry-run true, no other fields set (the minimal valid input).
    private static let minimalArguments: MCPToolArguments = {
        MCPToolArguments(["dry_run": .bool(true)])
    }()

    private static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPScanOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPScanOutput.self, from: data)
    }

    // MARK: Handler: happy path

    @Test("maps scan results to MCPScanOutput with correct item fields")
    func mapsItemFields() throws {
        let results = [
            Self.makeResult(
                id: "chrome_cache_001",
                size: 2_500_000_000, // 2.5 GB — AlertItem.formatBytes keeps the decimal under 10
                safety: .safe,
                category: "browser_cache",
                path: "/Users/me/Library/Caches/Google/Chrome",
                name: "Chrome Browser Cache",
                source: "Google Chrome",
                confidence: 99,
                explanation: "Browser cache files. Regenerated automatically."
            ),
        ]
        let subject = handler(scanner: { _ in results })
        let toolResult = try subject.handle(Self.minimalArguments)
        #expect(toolResult.isError == false)
        let output = try Self.decodeOutput(toolResult)
        #expect(output.items.count == 1)
        let item = output.items[0]
        #expect(item.id == "chrome_cache_001")
        #expect(item.name == "Chrome Browser Cache")
        #expect(item.path == "/Users/me/Library/Caches/Google/Chrome")
        #expect(item.size == "2.5 GB")
        #expect(item.safety == "safe")
        #expect(item.confidence == 99)
        #expect(item.explanation == "Browser cache files. Regenerated automatically.")
        #expect(item.source == "Google Chrome")
        #expect(item.category == "browser_cache")
        #expect(item.lastAccessed == Self.fixedDate)
    }

    @Test("totalReclaimable sums safe and review bytes but excludes protected")
    func totalReclaimableExcludesProtected() throws {
        let results = [
            Self.makeResult(id: "a", size: 1_000_000_000, safety: .safe),
            Self.makeResult(id: "b", size: 500_000_000, safety: .review),
            Self.makeResult(id: "c", size: 999_999_999_999, safety: .protected_),
        ]
        let subject = handler(scanner: { _ in results })
        let output = try Self.decodeOutput(try subject.handle(Self.minimalArguments))
        // 1_500_000_000 bytes = 1.5 GB via base-10 formatting
        #expect(output.totalReclaimable == "1.5 GB")
    }

    @Test("summary counts and sizes reflect each safety tier")
    func summaryCountsPerTier() throws {
        let results = [
            Self.makeResult(id: "s1", size: 100_000_000, safety: .safe),
            Self.makeResult(id: "s2", size: 200_000_000, safety: .safe),
            Self.makeResult(id: "r1", size: 300_000_000, safety: .review),
            Self.makeResult(id: "p1", size: 9_999_999_999, safety: .protected_),
            Self.makeResult(id: "p2", size: 1_234_567_890, safety: .protected_),
        ]
        let subject = handler(scanner: { _ in results })
        let output = try Self.decodeOutput(try subject.handle(Self.minimalArguments))
        #expect(output.summary.safeCount == 2)
        #expect(output.summary.safeSize == "300 MB")
        #expect(output.summary.reviewCount == 1)
        #expect(output.summary.reviewSize == "300 MB")
        #expect(output.summary.protectedCount == 2)
    }

    @Test("empty scan produces zero counts and 0-byte total")
    func emptyScan() throws {
        let subject = handler(scanner: { _ in [] })
        let output = try Self.decodeOutput(try subject.handle(Self.minimalArguments))
        #expect(output.items.isEmpty)
        #expect(output.totalReclaimable == "0 bytes")
        #expect(output.summary.safeCount == 0)
        #expect(output.summary.reviewCount == 0)
        #expect(output.summary.protectedCount == 0)
    }

    @Test("result is .structured with non-empty text summary")
    func structuredResultShape() throws {
        let results = [Self.makeResult(id: "a", size: 10_000, safety: .safe)]
        let subject = handler(scanner: { _ in results })
        let toolResult = try subject.handle(Self.minimalArguments)
        #expect(toolResult.isError == false)
        #expect(toolResult.structuredContent != nil)
        guard case .text(let summary) = toolResult.content.first else {
            Issue.record("content[0] should be a text block")
            return
        }
        #expect(summary.contains("1 items"))
        #expect(summary.contains("reclaimable"))
    }

    // MARK: Profile resolution

    @Test("resolver is called with nil when profile omitted")
    func resolverReceivesNilForOmittedProfile() throws {
        let received = CapturedProfileRequest()
        let subject = handler(
            scanner: { _ in [] },
            resolver: { requested in
                received.value = .some(requested)
                return .light
            }
        )
        _ = try subject.handle(Self.minimalArguments)
        #expect(received.value == .some(nil))
    }

    @Test("resolver is called with the decoded profile name")
    func resolverReceivesProfileName() throws {
        let received = CapturedProfileRequest()
        let subject = handler(
            scanner: { _ in [] },
            resolver: { requested in
                received.value = .some(requested)
                return .developer
            }
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "profile": .string("developer"),
        ]))
        #expect(received.value == .some("developer"))
    }

    @Test("resolver rejection surfaces as invalidParams")
    func resolverRejection() throws {
        let subject = handler(
            scanner: { _ in [] },
            resolver: { _ in throw MCPToolError.invalidParams("Unknown profile: bogus") }
        )
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(true),
                "profile": .string("bogus"),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "Unknown profile: bogus")
        }
    }

    // MARK: Categories override

    @Test("categories override replaces profile categories in the effective profile")
    func categoriesOverrideApplied() throws {
        let receivedCategories = CapturedCategories()
        let resolver: MCPScanToolHandler.ProfileResolver = { _ in .developer }
        let subject = handler(
            scanner: { profile in
                receivedCategories.value = profile.categories
                return []
            },
            resolver: resolver
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "categories": .array([.string("browser_cache"), .string("trash")]),
        ]))
        #expect(receivedCategories.value == ["browser_cache", "trash"])
    }

    @Test("categories override preserves other profile fields (id, overrides)")
    func categoriesOverridePreservesOtherFields() throws {
        let receivedProfile = CapturedProfile()
        let subject = handler(
            scanner: { profile in
                receivedProfile.value = profile
                return []
            },
            resolver: { _ in .developer }
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "categories": .array([.string("browser_cache")]),
        ]))
        let profile = try #require(receivedProfile.value)
        #expect(profile.id == CleanupProfile.developer.id)
        #expect(profile.name == CleanupProfile.developer.name)
        #expect(profile.safetyOverrides.count == CleanupProfile.developer.safetyOverrides.count)
    }

    @Test("omitted categories leaves profile categories intact")
    func omittedCategoriesLeavesProfileIntact() throws {
        let receivedCategories = CapturedCategories()
        let subject = handler(
            scanner: { profile in
                receivedCategories.value = profile.categories
                return []
            },
            resolver: { _ in .developer }
        )
        _ = try subject.handle(Self.minimalArguments)
        #expect(receivedCategories.value == CleanupProfile.developer.categories)
    }

    @Test("empty categories array is rejected as invalidParams")
    func emptyCategoriesRejected() throws {
        let subject = handler(scanner: { _ in [] })
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(true),
                "categories": .array([]),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("categories"))
        }
    }

    // MARK: Dry-run enforcement

    @Test("dry_run: false is rejected as invalidParams")
    func dryRunFalseRejected() throws {
        let subject = handler(scanner: { _ in [] })
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(false),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — MCPScanInput rejects dry_run=false at decode.
        }
    }

    @Test("omitted dry_run defaults to true and scan runs")
    func omittedDryRunAllowed() throws {
        let invoked = CapturedFlag()
        let subject = handler(
            scanner: { _ in
                invoked.value = true
                return []
            }
        )
        _ = try subject.handle(arguments([:]))
        #expect(invoked.value == true)
    }

    // MARK: Scanner errors

    @Test("scanner throwing a generic error produces a tool-domain .failure")
    func scannerErrorSurfacesAsToolFailure() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom happened" }
        }
        let subject = handler(scanner: { _ in throw Boom() })
        let result = try subject.handle(Self.minimalArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("Scan failed"))
        #expect(message.contains("boom happened"))
    }

    @Test("scanner throwing MCPToolError.invalidParams rethrows for dispatcher")
    func scannerInvalidParamsRethrown() throws {
        let subject = handler(
            scanner: { _ in throw MCPToolError.invalidParams("bad categories") }
        )
        do {
            _ = try subject.handle(Self.minimalArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad categories")
        }
    }

    @Test("scanner throwing MCPToolError.internalError rethrows for dispatcher")
    func scannerInternalErrorRethrown() throws {
        let subject = handler(
            scanner: { _ in throw MCPToolError.internalError("rules missing") }
        )
        do {
            _ = try subject.handle(Self.minimalArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.internalError(let message) {
            #expect(message == "rules missing")
        }
    }

    // MARK: Malformed arguments

    @Test("unknown fields on arguments are ignored")
    func unknownFieldsIgnored() throws {
        let invoked = CapturedFlag()
        let subject = handler(
            scanner: { _ in
                invoked.value = true
                return []
            }
        )
        _ = try subject.handle(arguments([
            "dry_run": .bool(true),
            "garbage_field": .string("whatever"),
        ]))
        #expect(invoked.value == true)
    }

    @Test("categories of wrong type is rejected as invalidParams")
    func categoriesWrongType() throws {
        let subject = handler(scanner: { _ in [] })
        do {
            _ = try subject.handle(arguments([
                "dry_run": .bool(true),
                "categories": .string("browser_cache"),
            ]))
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams {
            // Expected — decode fails with type mismatch.
        }
    }

    // MARK: Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let invoked = CapturedFlag()
        let subject = handler(
            scanner: { _ in
                invoked.value = true
                return [Self.makeResult(id: "item-1", size: 1_024, safety: .safe)]
            }
        )
        dispatcher.register(tool: .scan, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(7),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object(["dry_run": .bool(true)]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)
        #expect(invoked.value == true)
        // Result envelope is the MCPToolCallResult {content, structuredContent, isError?}
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        guard case .array(let content) = envelope["content"] else {
            Issue.record("content must be an array")
            return
        }
        #expect(!content.isEmpty)
        #expect(envelope["structuredContent"] != nil)
        #expect(envelope["isError"] == nil) // omitted on success
    }

    @Test("dispatcher maps handler invalidParams to JSON-RPC -32602")
    func dispatcherMapsInvalidParams() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(scanner: { _ in [] })
        dispatcher.register(tool: .scan, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(8),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object([
                    "dry_run": .bool(false), // should be rejected at decode
                ]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        let error = try #require(response.error)
        #expect(error.code == MCPErrorCode.invalidParams)
    }

    @Test("dispatcher reports tool-domain .failure as isError=true, not JSON-RPC error")
    func dispatcherPropagatesDomainFailure() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        struct Boom: Error {}
        let subject = handler(scanner: { _ in throw Boom() })
        dispatcher.register(tool: .scan, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(9),
            method: "tools/call",
            params: .object([
                "name": .string("scan"),
                "arguments": .object(["dry_run": .bool(true)]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil) // tool-domain errors don't use JSON-RPC error slot
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["isError"] == .bool(true))
    }
}

// MARK: - Test capture helpers

// Swift Testing closures need `@Sendable`, and simple Bools/strings/arrays
// aren't cheap to thread-safely capture inline. These tiny reference types
// give tests a shared cell to write into without dragging in `@MainActor`.

private final class CapturedFlag: @unchecked Sendable {
    var value: Bool = false
}

private final class CapturedProfileRequest: @unchecked Sendable {
    /// Outer optional distinguishes "scanner never called" (nil) from
    /// "scanner called with nil profile id" (.some(nil)).
    var value: String??
}

private final class CapturedCategories: @unchecked Sendable {
    var value: [String]?
}

private final class CapturedProfile: @unchecked Sendable {
    var value: CleanupProfile?
}
