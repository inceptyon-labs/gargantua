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

private func itemIdArguments(_ id: String) -> MCPToolArguments {
    MCPToolArguments(["item_id": .string(id)])
}

@Suite("MCP explain tool handler input decoding")
struct MCPExplainToolHandlerInputTests {

    @Test("missing both path and item_id surfaces as invalidParams")
    func missingInputsInvalid() throws {
        let subject = makeHandler(explain: { _ in makeOutput() })
        do {
            _ = try subject.handle(MCPToolArguments([:]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams {
            // expected
        }
    }

    @Test("supplying both path and item_id surfaces as invalidParams")
    func conflictingInputsInvalid() throws {
        let subject = makeHandler(explain: { _ in makeOutput() })
        do {
            _ = try subject.handle(MCPToolArguments([
                "path": .string("/tmp/foo"),
                "item_id": .string("abc"),
            ]))
            Issue.record("handler should have thrown invalidParams")
        } catch MCPToolError.invalidParams {
            // expected
        }
    }

    @Test("path-only arguments are accepted and forwarded to provider")
    func pathAccepted() throws {
        var seen: MCPExplainInput?
        let subject = makeHandler(explain: { input in
            seen = input
            return makeOutput()
        })
        _ = try subject.handle(pathArguments("/tmp/foo"))
        #expect(seen?.path == "/tmp/foo")
        #expect(seen?.itemId == nil)
    }

    @Test("item_id-only arguments are accepted and forwarded to provider")
    func itemIdAccepted() throws {
        var seen: MCPExplainInput?
        let subject = makeHandler(explain: { input in
            seen = input
            return makeOutput()
        })
        _ = try subject.handle(itemIdArguments("abc"))
        #expect(seen?.path == nil)
        #expect(seen?.itemId == "abc")
    }
}
