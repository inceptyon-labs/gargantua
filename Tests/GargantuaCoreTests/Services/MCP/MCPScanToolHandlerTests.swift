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
        let decoder = JSONDecoder()
        // Handler encodes Dates as ISO-8601 strings; mirror that on decode so
        // `lastAccessed` round-trips cleanly.
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPScanOutput.self, from: data)
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

    @Test("last_accessed is encoded as ISO-8601 on the MCP wire, not numeric")
    func lastAccessedWireIsISO8601() throws {
        // 2026-04-11T14:30:00Z — matches the PRD §7.3 example payload.
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 11
        components.hour = 14
        components.minute = 30
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))

        let results = [
            Self.makeResult(id: "a", size: 1_024, safety: .safe, lastAccessed: date),
        ]
        let subject = handler(scanner: { _ in results })
        let toolResult = try subject.handle(Self.minimalArguments)
        let payload = try #require(toolResult.structuredContent)
        guard case .object(let root) = payload,
              case .array(let items) = root["items"],
              case .object(let firstItem) = items.first,
              case .string(let wireDate) = firstItem["last_accessed"] else {
            Issue.record("items[0].last_accessed should be a string on the wire")
            return
        }
        #expect(wireDate == "2026-04-11T14:30:00Z")
    }

    @Test("wire envelope contains snake_case keys matching the PRD contract")
    func wireKeysAreSnakeCase() throws {
        let results = [Self.makeResult(id: "a", size: 1_024, safety: .safe)]
        let subject = handler(scanner: { _ in results })
        let toolResult = try subject.handle(Self.minimalArguments)
        let payload = try #require(toolResult.structuredContent)
        guard case .object(let root) = payload else {
            Issue.record("payload should be an object")
            return
        }
        #expect(root["total_reclaimable"] != nil)
        #expect(root["items"] != nil)
        #expect(root["summary"] != nil)
        guard case .object(let summary) = root["summary"] else {
            Issue.record("summary should be an object")
            return
        }
        #expect(summary["safe_count"] != nil)
        #expect(summary["safe_size"] != nil)
        #expect(summary["review_count"] != nil)
        #expect(summary["review_size"] != nil)
        #expect(summary["protected_count"] != nil)
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

    // MARK: Wire-payload caps

    @Test("Wire output trims items array to the top N by size when the scan exceeds the cap")
    func wireOutputTrimsItemsToTopNBySize() throws {
        let cap = MCPScanToolHandler.maxItemsInWireOutput
        // 20 above the cap, with strictly increasing sizes so we can pin
        // exactly which items survive the trim.
        let extra = 20
        let results = (0..<(cap + extra)).map { idx in
            Self.makeResult(
                id: "item-\(String(format: "%04d", idx))",
                size: Int64(idx + 1) * 1_000,
                safety: .safe,
                explanation: "row \(idx)"
            )
        }
        let output = MCPScanToolHandler.makeOutput(from: results)

        // Items list is capped at maxItemsInWireOutput, but the summary
        // still reflects the full scan (so the agent can tell things were
        // trimmed).
        #expect(output.items.count == cap)
        #expect(output.summary.safeCount == cap + extra)

        // Trim keeps the largest entries. The smallest ID (item-0000, size 1k)
        // should be gone; the largest (item-0119, size 120k) should be present.
        let returnedIDs = Set(output.items.map(\.id))
        #expect(returnedIDs.contains("item-\(String(format: "%04d", cap + extra - 1))"))
        #expect(!returnedIDs.contains("item-0000"))
    }

    @Test("Wire output trims overlong explanations and suffixes with an ellipsis")
    func wireOutputTrimsExplanationLength() throws {
        let cap = MCPScanToolHandler.maxExplanationCharsInWireOutput
        let longExplanation = String(repeating: "x", count: cap + 50)
        let results = [Self.makeResult(id: "huge", size: 1_000, safety: .safe, explanation: longExplanation)]
        let output = MCPScanToolHandler.makeOutput(from: results)

        let item = try #require(output.items.first)
        #expect(item.explanation.count == cap + 1) // cap chars + the trailing ellipsis
        #expect(item.explanation.hasSuffix("\u{2026}"))
        #expect(item.explanation.hasPrefix(String(repeating: "x", count: 64))) // body is preserved
    }

    @Test("Wire output leaves short explanations untouched")
    func wireOutputPreservesShortExplanations() throws {
        let results = [Self.makeResult(id: "small", size: 1_000, safety: .safe, explanation: "short note")]
        let output = MCPScanToolHandler.makeOutput(from: results)
        #expect(output.items.first?.explanation == "short note")
    }

    @Test("Summary text reports 'top N of M' when items are trimmed; otherwise reports raw count")
    func summaryTextReflectsTrim() throws {
        let cap = MCPScanToolHandler.maxItemsInWireOutput

        // Trimmed case.
        let trimmedResults = (0..<(cap + 5)).map { idx in
            Self.makeResult(id: "item-\(idx)", size: Int64(idx + 1) * 1_000, safety: .safe)
        }
        let trimmedSubject = handler(scanner: { _ in trimmedResults })
        let trimmedToolResult = try trimmedSubject.handle(Self.minimalArguments)
        guard case .text(let trimmedSummary) = trimmedToolResult.content.first else {
            Issue.record("expected a text content block")
            return
        }
        #expect(trimmedSummary.contains("Scan found \(cap + 5) items"))
        #expect(trimmedSummary.contains("returning the top \(cap)"))

        // Untrimmed case.
        let smallResults = [Self.makeResult(id: "only", size: 100, safety: .safe)]
        let smallSubject = handler(scanner: { _ in smallResults })
        let smallToolResult = try smallSubject.handle(Self.minimalArguments)
        guard case .text(let smallSummary) = smallToolResult.content.first else {
            Issue.record("expected a text content block")
            return
        }
        #expect(smallSummary.contains("Scan found 1 items"))
        #expect(!smallSummary.contains("returning the top"))
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
}

// MARK: - Test capture helpers

// Swift Testing closures need `@Sendable`, and simple Bools/strings/arrays
// aren't cheap to thread-safely capture inline. These tiny reference types
// give tests a shared cell to write into without dragging in `@MainActor`.

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
