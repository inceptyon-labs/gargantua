import Foundation
import Testing
@testable import GargantuaCore

@Suite("CommandActionExecutor")
struct CommandActionExecutorTests {
    private struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]
        private let defaultOutput: ProcessOutput

        init(
            outputs: [String: ProcessOutput],
            defaultOutput: ProcessOutput = ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        ) {
            self.outputs = outputs
            self.defaultOutput = defaultOutput
        }

        var calls: [StubCall] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
            lock.lock()
            _calls.append(StubCall(executable: executable.path, arguments: arguments, timeout: timeout))
            lock.unlock()
            let key = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            return outputs[key] ?? defaultOutput
        }
    }

    private final class AuditSpy: DeveloperToolAuditRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [AuditEntry] = []

        var entries: [AuditEntry] {
            lock.lock(); defer { lock.unlock() }
            return _entries
        }

        func write(_ entry: AuditEntry) throws {
            lock.lock()
            _entries.append(entry)
            lock.unlock()
        }
    }

    // MARK: - Fixtures

    private func makeScratchBinary(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandActionExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func resolver(tool: String, binary: URL) -> CommandActionToolResolver {
        CommandActionToolResolver(
            candidates: [tool: [binary.path]],
            environment: [:]
        )
    }

    private func makeRule(
        id: String = "test_rule",
        tool: String = "pnpm",
        arguments: [String] = ["store", "prune"],
        dryRunArguments: [String]? = nil,
        safety: SafetyLevel = .safe
    ) -> CommandActionRule {
        CommandActionRule(
            id: id,
            name: "Test rule",
            tool: tool,
            arguments: arguments,
            dryRunArguments: dryRunArguments,
            safety: safety,
            confidence: 90,
            explanation: "Test rule",
            category: "developer_tool_command",
            affectedRoots: ["~/Library/test"],
            source: SourceAttribution(name: tool)
        )
    }

    // MARK: - Preview

    @Test("Preview without dry-run downgrades safe to review")
    func previewDowngradesSafeToReview() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let executor = CommandActionExecutor(
            resolver: resolver(tool: "pnpm", binary: pnpm),
            runner: StubRunner(outputs: ["pnpm --version": ProcessOutput(stdout: "9.10.0\n", stderr: "", exitCode: 0)]),
            auditRecorder: AuditSpy()
        )

        let preview = try executor.preview(makeRule(safety: .safe))
        #expect(preview.effectiveSafety == .review)
        #expect(preview.estimatedBytes == nil)
        #expect(preview.toolVersion == "9.10.0")
    }

    @Test("Preview keeps safe when an estimator returns bytes")
    func previewKeepsSafeWithEstimator() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "pnpm --version": ProcessOutput(stdout: "9.10.0\n", stderr: "", exitCode: 0),
            "pnpm store prune --dry-run": ProcessOutput(stdout: "Will reclaim 25 MB\n", stderr: "", exitCode: 0),
        ])
        let estimators: [String: CommandActionBytesEstimator] = [
            "test_rule": { _, _ in 25_000_000 },
        ]
        let executor = CommandActionExecutor(
            resolver: resolver(tool: "pnpm", binary: pnpm),
            runner: runner,
            auditRecorder: AuditSpy(),
            bytesEstimators: estimators
        )

        let rule = makeRule(dryRunArguments: ["store", "prune", "--dry-run"], safety: .safe)
        let preview = try executor.preview(rule)
        #expect(preview.effectiveSafety == .safe)
        #expect(preview.estimatedBytes == 25_000_000)
    }

    @Test("Preview downgrades safe to review when estimator returns nil")
    func previewDowngradesWhenEstimatorReturnsNil() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "pnpm --version": ProcessOutput(stdout: "9.10.0\n", stderr: "", exitCode: 0),
            "pnpm store prune --dry-run": ProcessOutput(stdout: "?\n", stderr: "", exitCode: 0),
        ])
        let estimators: [String: CommandActionBytesEstimator] = [
            "test_rule": { _, _ in nil },
        ]
        let executor = CommandActionExecutor(
            resolver: resolver(tool: "pnpm", binary: pnpm),
            runner: runner,
            auditRecorder: AuditSpy(),
            bytesEstimators: estimators
        )

        let rule = makeRule(dryRunArguments: ["store", "prune", "--dry-run"], safety: .safe)
        let preview = try executor.preview(rule)
        #expect(preview.effectiveSafety == .review)
        #expect(preview.estimatedBytes == nil)
    }

    @Test("Preview throws when the tool is not installed")
    func previewThrowsWhenToolMissing() throws {
        // Empty resolver — no candidates, no env override.
        let executor = CommandActionExecutor(
            resolver: CommandActionToolResolver(candidates: [:], environment: [:]),
            runner: StubRunner(outputs: [:]),
            auditRecorder: AuditSpy()
        )

        #expect(throws: CommandActionExecutionError.toolNotInstalled(tool: "pnpm")) {
            _ = try executor.preview(makeRule())
        }
    }

    // MARK: - Execute

    @Test("Successful execution writes a kind: command audit entry")
    func executeWritesCommandAuditEntry() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let runner = StubRunner(outputs: [
            "pnpm --version": ProcessOutput(stdout: "9.10.0\n", stderr: "", exitCode: 0),
            "pnpm store prune": ProcessOutput(stdout: "ok\n", stderr: "", exitCode: 0),
        ])
        let executor = CommandActionExecutor(
            resolver: resolver(tool: "pnpm", binary: pnpm),
            runner: runner,
            auditRecorder: audit
        )

        let rule = makeRule()
        let preview = try executor.preview(rule)
        let result = try executor.execute(rule, preview: preview, confirmationMethod: .summaryDialog)

        #expect(result.output.exitCode == 0)
        let entry = try #require(audit.entries.first)
        #expect(entry.kind == .command)
        #expect(entry.tool == "command-action")
        #expect(entry.command == "pnpm store prune")
        #expect(entry.files.isEmpty)
        // Effective safety reaches the audit entry, not the YAML floor.
        #expect(entry.safetyLevel == .review)
        #expect(entry.confirmationMethod == .summaryDialog)
        #expect(entry.cleanupMethod == .toolNative)
        #expect(entry.bytesFreed == 0)
        #expect(entry.commandToolVersion == "9.10.0")
        #expect(entry.commandExitCode == 0)
        #expect(entry.commandArguments == ["store", "prune"])
    }

    @Test("Failure surfaces stderr and writes no audit entry")
    func executeFailureSkipsAudit() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let audit = AuditSpy()
        let runner = StubRunner(outputs: [
            "pnpm --version": ProcessOutput(stdout: "9.10.0\n", stderr: "", exitCode: 0),
            "pnpm store prune": ProcessOutput(stdout: "", stderr: "store offline\n", exitCode: 1),
        ])
        let executor = CommandActionExecutor(
            resolver: resolver(tool: "pnpm", binary: pnpm),
            runner: runner,
            auditRecorder: audit
        )

        let rule = makeRule()
        let preview = try executor.preview(rule)

        #expect(throws: CommandActionExecutionError.commandFailed(
            ruleID: "test_rule",
            exitCode: 1,
            stderr: "store offline"
        )) {
            _ = try executor.execute(rule, preview: preview, confirmationMethod: .summaryDialog)
        }
        #expect(audit.entries.isEmpty)
    }

    // MARK: - Resolver

    @Test("Tool resolver honors the GARGANTUA_TOOL_<NAME> env override")
    func resolverHonorsEnvOverride() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let resolver = CommandActionToolResolver(
            candidates: ["pnpm": ["/dev/null/missing"]],
            environment: ["GARGANTUA_TOOL_PNPM": pnpm.path]
        )
        #expect(resolver.resolve(tool: "pnpm")?.path == pnpm.path)
    }

    @Test("Audit JSONL decodes legacy entries lacking the kind discriminator")
    func legacyAuditEntryDecodesAsPath() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "timestamp": "2026-01-01T00:00:00Z",
          "tool": "native",
          "command": "clean",
          "files": [],
          "safetyLevel": "safe",
          "confirmationMethod": "singleButton",
          "cleanupMethod": "trash",
          "bytesFreed": 1024
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(AuditEntry.self, from: Data(legacyJSON.utf8))
        #expect(entry.kind == .path)
        #expect(entry.commandToolVersion == nil)
        #expect(entry.commandExitCode == nil)
        #expect(entry.commandArguments == nil)
    }
}
