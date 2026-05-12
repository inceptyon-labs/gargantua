import Foundation
import os
import Testing
@testable import GargantuaCore

// JSONL test fixtures — see ClaudeCodeStreamJSONParserTests.swift for rationale.

@Suite("Claude Code Agent Tier 3")
struct ClaudeCodeAgentTests {
    func makeDefaults() throws -> UserDefaults {
        let suite = "gargantua-claude-code-agent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func makeExecutable(named name: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
        return url
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-claude-code-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class FakeClaudeCodeProcessExecutor: ClaudeCodeAgentProcessExecuting, @unchecked Sendable {
    private struct State {
        var didCancel = false
        var lastArguments: [String] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let outputs: [ClaudeCodeProcessOutput]
    private let exitCode: Int32

    init(outputs: [ClaudeCodeProcessOutput] = [], exitCode: Int32 = 0) {
        self.outputs = outputs
        self.exitCode = exitCode
    }

    var didCancel: Bool {
        lock.withLock { $0.didCancel }
    }

    var lastArguments: [String] {
        lock.withLock { $0.lastArguments }
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        onOutput: @escaping @Sendable (ClaudeCodeProcessOutput) -> Void
    ) async throws -> Int32 {
        lock.withLock { $0.lastArguments = arguments }

        for output in outputs {
            onOutput(output)
        }
        return exitCode
    }

    func cancel() {
        lock.withLock { $0.didCancel = true }
    }
}

final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        values.append(element)
        lock.unlock()
    }

    func all() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
