import Foundation
import Testing
@testable import GargantuaCore

@Suite("CommandActionScanAdapter")
struct CommandActionScanAdapterTests {
    private final class StubExecutor: CommandActionExecuting, @unchecked Sendable {
        var previewBytes: Int64?
        var previewError: Error?

        func preview(_ rule: CommandActionRule) throws -> CommandActionPreview {
            if let previewError { throw previewError }
            let safety: SafetyLevel = previewBytes == nil
                ? (rule.safety == .safe ? .review : rule.safety)
                : rule.safety
            return CommandActionPreview(
                rule: rule,
                effectiveSafety: safety,
                estimatedBytes: previewBytes,
                toolVersion: "stub-1.0",
                dryRunOutput: nil
            )
        }

        func execute(
            _ rule: CommandActionRule,
            preview: CommandActionPreview,
            confirmationMethod: ConfirmationTier
        ) throws -> CommandActionExecutionResult {
            CommandActionExecutionResult(
                rule: rule,
                commandPreview: [rule.tool] + rule.arguments,
                output: ProcessOutput(stdout: "", stderr: "", exitCode: 0),
                estimatedBytesFreed: 0,
                toolVersion: preview.toolVersion
            )
        }
    }

    private func rule(
        id: String = "rule_a",
        tool: String = "pnpm",
        category: String = "developer_tool_command"
    ) -> CommandActionRule {
        CommandActionRule(
            id: id,
            name: "Rule \(id)",
            tool: tool,
            arguments: ["store", "prune"],
            safety: .safe,
            confidence: 90,
            explanation: "test rule",
            category: category,
            affectedRoots: ["~/Library/test"],
            source: SourceAttribution(name: tool)
        )
    }

    private func makeBinary(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandActionScanAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func resolver(tool: String, binary: URL) -> CommandActionToolResolver {
        CommandActionToolResolver(candidates: [tool: [binary.path]], environment: [:])
    }

    @Test("Synthesizes a ScanResult per available rule with the command-action prefix")
    func synthesizesScanResults() async throws {
        let pnpm = try makeBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let executor = StubExecutor()
        let adapter = CommandActionScanAdapter(
            rules: [rule(id: "alpha"), rule(id: "beta")],
            executor: executor,
            resolver: resolver(tool: "pnpm", binary: pnpm)
        )

        let results = try await adapter.scan(progress: nil)
        #expect(results.count == 2)
        let r = try #require(results.first)
        #expect(r.id == "command-action:alpha")
        #expect(r.path == "pnpm store prune")
        #expect(r.isCommandAction)
        #expect(r.commandActionRuleID == "alpha")
        #expect(r.tags.contains("command-action"))
        #expect(r.tags.contains("command-action:unknown-bytes"))
        // safe → review when no bytes estimate
        #expect(r.safety == .review)
    }

    @Test("Skips rules whose tool is not installed")
    func skipsMissingTool() async throws {
        let executor = StubExecutor()
        let adapter = CommandActionScanAdapter(
            rules: [rule(id: "alpha")],
            executor: executor,
            // Empty candidate map so resolve() returns nil.
            resolver: CommandActionToolResolver(candidates: [:], environment: [:])
        )
        let results = try await adapter.scan(progress: nil)
        #expect(results.isEmpty)
    }

    @Test("Filters out rules whose category is excluded by the active profile")
    func categoryFilter() async throws {
        let pnpm = try makeBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let adapter = CommandActionScanAdapter(
            rules: [
                rule(id: "alpha", category: "developer_tool_command"),
                rule(id: "beta", category: "different_category"),
            ],
            executor: StubExecutor(),
            resolver: resolver(tool: "pnpm", binary: pnpm),
            categories: ["developer_tool_command"]
        )

        let results = try await adapter.scan(progress: nil)
        #expect(results.count == 1)
        #expect(results.first?.commandActionRuleID == "alpha")
    }

    @Test("Failed preview drops the rule rather than failing the whole scan")
    func previewFailureDropsRule() async throws {
        let pnpm = try makeBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let executor = StubExecutor()
        executor.previewError = CommandActionExecutionError.toolNotInstalled(tool: "pnpm")

        let adapter = CommandActionScanAdapter(
            rules: [rule(id: "alpha")],
            executor: executor,
            resolver: resolver(tool: "pnpm", binary: pnpm)
        )
        let results = try await adapter.scan(progress: nil)
        #expect(results.isEmpty)
    }

    @Test("CompositeScanAdapter concatenates primary and best-effort results")
    func compositeConcatenates() async throws {
        struct StaticAdapter: ScanAdapter {
            let results: [ScanResult]
            func scan(progress: ScanProgress?) async throws -> [ScanResult] { results }
        }
        let primary = StaticAdapter(results: [
            ScanResult(
                id: "path:1",
                name: "path",
                path: "/tmp/file",
                size: 100,
                safety: .safe,
                confidence: 100,
                explanation: "x",
                source: SourceAttribution(name: "test"),
                category: "system_cache"
            )
        ])
        let pnpm = try makeBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }
        let cmdAdapter = CommandActionScanAdapter(
            rules: [rule(id: "alpha")],
            executor: StubExecutor(),
            resolver: resolver(tool: "pnpm", binary: pnpm)
        )

        let composite = CompositeScanAdapter(primary: primary, bestEffort: [cmdAdapter])
        let results = try await composite.scan(progress: nil)
        #expect(results.count == 2)
        #expect(results.contains { $0.id == "path:1" })
        #expect(results.contains { $0.id == "command-action:alpha" })
    }

    @Test("CompositeScanAdapter swallows best-effort adapter failures")
    func compositeSwallowsBestEffortFailures() async throws {
        struct ThrowingAdapter: ScanAdapter {
            func scan(progress: ScanProgress?) async throws -> [ScanResult] {
                throw NSError(domain: "test", code: 1)
            }
        }
        struct StaticAdapter: ScanAdapter {
            let results: [ScanResult]
            func scan(progress: ScanProgress?) async throws -> [ScanResult] { results }
        }
        let primary = StaticAdapter(results: [
            ScanResult(
                id: "path:1",
                name: "path",
                path: "/tmp/file",
                size: 0,
                safety: .safe,
                confidence: 100,
                explanation: "",
                source: SourceAttribution(name: "test"),
                category: "system_cache"
            )
        ])
        let composite = CompositeScanAdapter(primary: primary, bestEffort: [ThrowingAdapter()])
        let results = try await composite.scan(progress: nil)
        #expect(results.count == 1)
    }
}
