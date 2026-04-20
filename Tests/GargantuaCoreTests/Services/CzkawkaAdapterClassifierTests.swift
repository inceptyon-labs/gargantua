import Foundation
import Testing
@testable import GargantuaCore

/// Tests for `CzkawkaAdapter`'s `SafetyClassifier` wiring — the Phase 2 bridge
/// that lets czkawka findings share the same profile-aware Trust Layer
/// overrides (age-based, protected paths, …) that `NativeScanAdapter` already
/// applies to YAML-driven rule results.
@Suite("CzkawkaAdapter (SafetyClassifier wiring)")
struct CzkawkaAdapterClassifierTests {

    /// Deterministic `ProcessRunner` that replays canned stdout per subcommand.
    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let outputs: [String: ProcessOutput]

        init(outputs: [String: ProcessOutput]) {
            self.outputs = outputs
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            let subcommand = arguments.first ?? ""
            return outputs[subcommand] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private static func makeTempFile(byteCount: Int = 64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("target.bin")
        try Data(repeating: 0xCD, count: byteCount).write(to: url)
        return url
    }

    /// Set modification date so `resourceValues(.contentAccessDateKey)`
    /// fallback lands at a deterministic age for override evaluation.
    private static func setAccessTime(_ url: URL, daysAgo: Double) throws {
        let when = Date().addingTimeInterval(-daysAgo * 86400)
        try FileManager.default.setAttributes(
            [.modificationDate: when],
            ofItemAtPath: url.path
        )
    }

    @Test("without a profile, findings keep their base Trust Layer defaults")
    func noProfilePreservesBaseClassification() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setAccessTime(target, daysAgo: 60)

        let stdout = "Found 1 biggest files.\n4096 \(target.path)"
        let runner = StubRunner(outputs: [
            "big": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.bigFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.safety == .review)
    }

    @Test("developer profile downgrades 30+ day big-files to safe via SafetyClassifier")
    func developerProfileDowngradesAgedFindings() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setAccessTime(target, daysAgo: 60)

        let stdout = "Found 1 biggest files.\n4096 \(target.path)"
        let runner = StubRunner(outputs: [
            "big": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.bigFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner,
            profile: .developer
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.safety == .safe)
        #expect(results.first?.confidence == 95)
        #expect(results.first?.explanation.contains("No project activity in 30+ days.") == true)
    }

    @Test("developer profile leaves recent big-files at review")
    func developerProfileLeavesRecentFindings() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setAccessTime(target, daysAgo: 3)

        let stdout = "Found 1 biggest files.\n4096 \(target.path)"
        let runner = StubRunner(outputs: [
            "big": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.bigFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner,
            profile: .developer
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.safety == .review)
    }

    @Test("light profile (no age overrides) leaves base classifications intact")
    func lightProfilePreservesBaseClassification() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setAccessTime(target, daysAgo: 365)

        let stdout = "Found 1 biggest files.\n4096 \(target.path)"
        let runner = StubRunner(outputs: [
            "big": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.bigFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner,
            profile: .light
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.safety == .review)
    }
}
