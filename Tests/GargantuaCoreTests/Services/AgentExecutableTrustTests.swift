import Foundation
import Testing
@testable import GargantuaCore

@Suite("Agent CLI executable trust")
struct AgentExecutableTrustTests {
    @Test("An Agent CLI binary writable by group or others is refused before launch")
    func groupWritableBinaryRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentExecutableTrustTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: binary.path)

        await #expect(throws: ExecutableTrustPolicy.Violation.self) {
            _ = try await FoundationClaudeCodeProcessExecutor().start(
                executable: binary, arguments: [], environment: [:], workingDirectory: nil, onOutput: { _ in }
            )
        }
        await #expect(throws: ExecutableTrustPolicy.Violation.self) {
            _ = try await CodexOneShotRunner().run(executable: binary, prompt: "x", model: "")
        }
        await #expect(throws: ExecutableTrustPolicy.Violation.self) {
            _ = try await ClaudeCodeOneShotRunner().run(executable: binary, prompt: "x", model: "")
        }
    }
}
