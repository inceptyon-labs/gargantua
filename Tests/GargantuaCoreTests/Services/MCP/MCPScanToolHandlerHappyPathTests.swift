import Testing
import Foundation
@testable import GargantuaCore

private let fixedDate = Date(timeIntervalSince1970: 1_744_819_200) // 2025-04-16 16:00:00 UTC

private func makeResult(
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

private func makeHandler(
    scanner: @escaping MCPScanToolHandler.Scanner,
    resolver: @escaping MCPScanToolHandler.ProfileResolver = { _ in .light }
) -> MCPScanToolHandler {
    MCPScanToolHandler(scanner: scanner, profileResolver: resolver)
}

private let minimalArguments = MCPToolArguments(["dry_run": .bool(true)])

private func decodeOutput(_ result: MCPToolCallResult) throws -> MCPScanOutput {
    let payload = try #require(result.structuredContent, "structured content missing")
    let data = try JSONEncoder().encode(payload)
    let decoder = JSONDecoder()
    // Handler encodes Dates as ISO-8601 strings; mirror that on decode so
    // `lastAccessed` round-trips cleanly.
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MCPScanOutput.self, from: data)
}

@Suite("MCP scan tool handler happy path")
struct MCPScanToolHandlerHappyPathTests {

    @Test("maps scan results to MCPScanOutput with correct item fields")
    func mapsItemFields() throws {
        let results = [
            makeResult(
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
        let subject = makeHandler(scanner: { _ in results })
        let toolResult = try subject.handle(minimalArguments)
        #expect(toolResult.isError == false)
        let output = try decodeOutput(toolResult)
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
        #expect(item.lastAccessed == fixedDate)
    }

    @Test("totalReclaimable sums safe and review bytes but excludes protected")
    func totalReclaimableExcludesProtected() throws {
        let results = [
            makeResult(id: "a", size: 1_000_000_000, safety: .safe),
            makeResult(id: "b", size: 500_000_000, safety: .review),
            makeResult(id: "c", size: 999_999_999_999, safety: .protected_),
        ]
        let subject = makeHandler(scanner: { _ in results })
        let output = try decodeOutput(try subject.handle(minimalArguments))
        // 1_500_000_000 bytes = 1.5 GB via base-10 formatting
        #expect(output.totalReclaimable == "1.5 GB")
    }

    @Test("summary counts and sizes reflect each safety tier")
    func summaryCountsPerTier() throws {
        let results = [
            makeResult(id: "s1", size: 100_000_000, safety: .safe),
            makeResult(id: "s2", size: 200_000_000, safety: .safe),
            makeResult(id: "r1", size: 300_000_000, safety: .review),
            makeResult(id: "p1", size: 9_999_999_999, safety: .protected_),
            makeResult(id: "p2", size: 1_234_567_890, safety: .protected_),
        ]
        let subject = makeHandler(scanner: { _ in results })
        let output = try decodeOutput(try subject.handle(minimalArguments))
        #expect(output.summary.safeCount == 2)
        #expect(output.summary.safeSize == "300 MB")
        #expect(output.summary.reviewCount == 1)
        #expect(output.summary.reviewSize == "300 MB")
        #expect(output.summary.protectedCount == 2)
    }

    @Test("empty scan produces zero counts and 0-byte total")
    func emptyScan() throws {
        let subject = makeHandler(scanner: { _ in [] })
        let output = try decodeOutput(try subject.handle(minimalArguments))
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

        let results = [makeResult(id: "a", size: 1_024, safety: .safe, lastAccessed: date)]
        let subject = makeHandler(scanner: { _ in results })
        let toolResult = try subject.handle(minimalArguments)
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
        let results = [makeResult(id: "a", size: 1_024, safety: .safe)]
        let subject = makeHandler(scanner: { _ in results })
        let toolResult = try subject.handle(minimalArguments)
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
        let results = [makeResult(id: "a", size: 10_000, safety: .safe)]
        let subject = makeHandler(scanner: { _ in results })
        let toolResult = try subject.handle(minimalArguments)
        #expect(toolResult.isError == false)
        #expect(toolResult.structuredContent != nil)
        guard case .text(let summary) = toolResult.content.first else {
            Issue.record("content[0] should be a text block")
            return
        }
        #expect(summary.contains("1 items"))
        #expect(summary.contains("reclaimable"))
    }
}
