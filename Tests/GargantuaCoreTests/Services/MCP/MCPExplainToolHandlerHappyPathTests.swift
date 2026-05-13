import Testing
import Foundation
@testable import GargantuaCore

private func makeOutput(
    name: String = "node_modules",
    safety: String = "review",
    confidence: Int = 50,
    explanation: String = "No AI-backed analysis available yet.",
    size: String? = "128 MB",
    lastAccessed: Date? = nil
) -> MCPExplainOutput {
    MCPExplainOutput(
        name: name,
        safety: safety,
        confidence: confidence,
        explanation: explanation,
        size: size,
        lastAccessed: lastAccessed
    )
}

private func makeHandler(
    explain: @escaping @Sendable (MCPExplainInput) throws -> MCPExplainOutput
) -> MCPExplainToolHandler {
    MCPExplainToolHandler(explainProvider: explain)
}

private func pathArguments(_ path: String) -> MCPToolArguments {
    MCPToolArguments(["path": .string(path)])
}

private func decodeOutput(_ result: MCPToolCallResult) throws -> MCPExplainOutput {
    let payload = try #require(result.structuredContent, "structured content missing")
    let data = try JSONEncoder().encode(payload)
    // MCPExplainOutput.lastAccessed is Date? encoded as ISO-8601 via
    // MCPEncoding; decode with the matching strategy to round-trip it.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MCPExplainOutput.self, from: data)
}

@Suite("MCP explain tool handler happy path")
struct MCPExplainToolHandlerHappyPathTests {

    @Test("maps provider output into MCPExplainOutput core fields")
    func mapsCoreFields() throws {
        let expected = makeOutput(
            name: "node_modules",
            safety: "review",
            confidence: 65,
            explanation: "Project dependency cache.",
            size: "128 MB"
        )
        let subject = makeHandler(explain: { _ in expected })
        let result = try subject.handle(pathArguments("/Users/x/project/node_modules"))
        #expect(result.isError == false)
        let output = try decodeOutput(result)
        #expect(output.name == expected.name)
        #expect(output.safety == expected.safety)
        #expect(output.confidence == expected.confidence)
        #expect(output.explanation == expected.explanation)
        #expect(output.size == expected.size)
    }

    @Test("lastAccessed Date round-trips as ISO-8601 on the wire")
    func lastAccessedIso8601() throws {
        let fixed = Date(timeIntervalSince1970: 1_712_836_200) // 2024-04-11T11:10:00Z
        let subject = makeHandler(explain: { _ in makeOutput(lastAccessed: fixed) })
        let payload = try #require(
            try subject.handle(pathArguments("/tmp/foo")).structuredContent
        )
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        guard case .string(let lastAccessed) = root["last_accessed"] else {
            Issue.record("last_accessed should be an ISO-8601 string")
            return
        }
        // Sanity-check the shape; exact formatting comes from JSONEncoder's
        // .iso8601 strategy so avoid asserting the literal millisecond suffix.
        #expect(lastAccessed.hasPrefix("2024-04-11T"))
        #expect(lastAccessed.hasSuffix("Z"))
    }

    @Test("size is omitted from the wire payload when nil")
    func sizeNilOmitted() throws {
        let subject = makeHandler(explain: { _ in makeOutput(size: nil) })
        let payload = try #require(
            try subject.handle(pathArguments("/tmp/foo")).structuredContent
        )
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["size"] == nil)
    }

    @Test("wire envelope uses snake_case keys matching PRD contract")
    func wireKeysSnakeCase() throws {
        let fixed = Date(timeIntervalSince1970: 1_712_836_200)
        let subject = makeHandler(explain: { _ in makeOutput(lastAccessed: fixed) })
        let payload = try #require(
            try subject.handle(pathArguments("/tmp/foo")).structuredContent
        )
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["name"] != nil)
        #expect(root["safety"] != nil)
        #expect(root["confidence"] != nil)
        #expect(root["explanation"] != nil)
        #expect(root["size"] != nil)
        #expect(root["last_accessed"] != nil)
    }

    @Test("result is .structured with text summary derived from output")
    func structuredResultShape() throws {
        let subject = makeHandler(explain: { _ in
            makeOutput(name: "cache.db", size: "1.2 GB")
        })
        let result = try subject.handle(pathArguments("/tmp/cache.db"))
        #expect(result.isError == false)
        #expect(result.structuredContent != nil)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("cache.db"))
        #expect(summary.contains("1.2 GB"))
        #expect(summary.contains("review"))
    }
}
