import Testing
import Foundation
@testable import GargantuaCore

private let fixedDate = Date(timeIntervalSince1970: 1_744_819_200)

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

@Suite("MCP scan tool handler wire-payload caps")
struct MCPScanToolHandlerWireCapsTests {

    @Test("Wire output trims items array to the top N by size when the scan exceeds the cap")
    func wireOutputTrimsItemsToTopNBySize() throws {
        let cap = MCPScanToolHandler.maxItemsInWireOutput
        // 20 above the cap, with strictly increasing sizes so we can pin
        // exactly which items survive the trim.
        let extra = 20
        let results = (0 ..< (cap + extra)).map { idx in
            makeResult(
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
        let results = [makeResult(id: "huge", size: 1_000, safety: .safe, explanation: longExplanation)]
        let output = MCPScanToolHandler.makeOutput(from: results)

        let item = try #require(output.items.first)
        #expect(item.explanation.count == cap + 1) // cap chars + the trailing ellipsis
        #expect(item.explanation.hasSuffix("\u{2026}"))
        #expect(item.explanation.hasPrefix(String(repeating: "x", count: 64))) // body is preserved
    }

    @Test("Wire output leaves short explanations untouched")
    func wireOutputPreservesShortExplanations() throws {
        let results = [makeResult(id: "small", size: 1_000, safety: .safe, explanation: "short note")]
        let output = MCPScanToolHandler.makeOutput(from: results)
        #expect(output.items.first?.explanation == "short note")
    }

    @Test("Summary text reports 'top N of M' when items are trimmed; otherwise reports raw count")
    func summaryTextReflectsTrim() throws {
        let cap = MCPScanToolHandler.maxItemsInWireOutput

        // Trimmed case.
        let trimmedResults = (0 ..< (cap + 5)).map { idx in
            makeResult(id: "item-\(idx)", size: Int64(idx + 1) * 1_000, safety: .safe)
        }
        let trimmedSubject = makeHandler(scanner: { _ in trimmedResults })
        let trimmedToolResult = try trimmedSubject.handle(minimalArguments)
        guard case .text(let trimmedSummary) = trimmedToolResult.content.first else {
            Issue.record("expected a text content block")
            return
        }
        #expect(trimmedSummary.contains("Scan found \(cap + 5) items"))
        #expect(trimmedSummary.contains("returning the top \(cap)"))

        // Untrimmed case.
        let smallResults = [makeResult(id: "only", size: 100, safety: .safe)]
        let smallSubject = makeHandler(scanner: { _ in smallResults })
        let smallToolResult = try smallSubject.handle(minimalArguments)
        guard case .text(let smallSummary) = smallToolResult.content.first else {
            Issue.record("expected a text content block")
            return
        }
        #expect(smallSummary.contains("Scan found 1 items"))
        #expect(!smallSummary.contains("returning the top"))
    }
}
