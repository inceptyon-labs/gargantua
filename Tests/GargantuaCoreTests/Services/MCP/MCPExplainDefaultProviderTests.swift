import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP explain default filesystem provider")
struct MCPExplainDefaultProviderTests {

    // MARK: Input validation

    @Test("item_id input is rejected with invalidParams")
    func itemIdRejected() throws {
        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        do {
            _ = try provider(MCPExplainInput(itemId: "abc"))
            Issue.record("provider should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.contains("item_id"))
        }
    }

    @Test("empty path input is rejected with invalidParams")
    func emptyPathRejected() throws {
        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        do {
            _ = try provider(MCPExplainInput(path: ""))
            Issue.record("provider should have thrown")
        } catch MCPToolError.invalidParams {
            // expected
        }
    }

    @Test("relative path input is rejected with invalidParams (contract says absolute)")
    func relativePathRejected() throws {
        // MCPPhase2Tools.explain advertises path as an "Absolute filesystem
        // path". Accepting relative paths would silently resolve against the
        // MCP process CWD and produce surprising metadata depending on
        // launch context.
        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        do {
            _ = try provider(MCPExplainInput(path: "Documents/foo.txt"))
            Issue.record("provider should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message.lowercased().contains("absolute"))
        }
    }

    @Test("tilde path input is rejected (tilde is user-relative, not absolute)")
    func tildePathRejected() throws {
        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        do {
            _ = try provider(MCPExplainInput(path: "~/Documents"))
            Issue.record("provider should have thrown")
        } catch MCPToolError.invalidParams {
            // expected
        }
    }

    // MARK: Happy path — file

    @Test("absolute path to an existing file returns size + lastAccessed + basename")
    func existingFile() throws {
        let url = try Self.writeTempFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        let output = try provider(MCPExplainInput(path: url.path))

        #expect(output.name == url.lastPathComponent)
        #expect(output.safety == "review")
        #expect(output.confidence == 50)
        // AlertItem.formatBytes renders 1024B as "1.0 KB" (decimals are
        // kept for values < 10 of a unit, dropped otherwise).
        #expect(output.size == "1.0 KB")
        #expect(output.lastAccessed != nil)
        #expect(output.explanation.lowercased().contains("not yet wired"))
    }

    @Test("absolute path to an existing directory omits size but keeps lastAccessed")
    func existingDirectory() throws {
        // `.size` on a directory returns the inode size, not the recursive
        // total. The provider must omit that misleading value.
        let url = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        let output = try provider(MCPExplainInput(path: url.path))

        #expect(output.name == url.lastPathComponent)
        #expect(output.size == nil)
        #expect(output.lastAccessed != nil)
    }

    @Test("nonexistent absolute path returns a shell response with no metadata")
    func nonexistentPath() throws {
        // Shell contract: always render a conservative response for any
        // accepted input. A dedicated path-not-found signal lands with the
        // AI-backed provider that replaces this shell.
        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        let output = try provider(
            MCPExplainInput(path: "/this/path/does/not/exist/\(UUID().uuidString)")
        )
        #expect(output.safety == "review")
        #expect(output.confidence == 50)
        #expect(output.size == nil)
        #expect(output.lastAccessed == nil)
    }

    @Test("root path '/' returns basename '/' (URL.lastPathComponent edge case)")
    func rootPath() throws {
        let provider = MCPExplainToolHandler.defaultFilesystemProvider()
        let output = try provider(MCPExplainInput(path: "/"))
        // URL(fileURLWithPath: "/").lastPathComponent == "/", which the
        // provider's `isEmpty` guard already handles.
        #expect(!output.name.isEmpty)
    }

    // MARK: Wiring through the handler

    @Test("default provider wired through the handler produces a structured result")
    func wiringSmokeTest() throws {
        let url = try Self.writeTempFile(bytes: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let handler = MCPExplainToolHandler(
            explainProvider: MCPExplainToolHandler.defaultFilesystemProvider()
        )
        let result = try handler.handle(MCPToolArguments([
            "path": .string(url.path),
        ]))
        #expect(result.isError == false)
        #expect(result.structuredContent != nil)
    }

    // MARK: Fixtures

    private static func writeTempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-explain-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-explain-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
