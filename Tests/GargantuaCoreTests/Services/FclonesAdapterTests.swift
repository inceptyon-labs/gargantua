import Foundation
import Testing
@testable import GargantuaCore

@Suite("FclonesAdapter")
struct FclonesAdapterTests {

    // MARK: - Stub runner

    struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    /// Deterministic `ProcessRunner` that records calls and replays a canned
    /// `ProcessOutput`. Defaults to exit 0 / empty stdout.
    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let output: ProcessOutput
        private let runError: Error?

        init(output: ProcessOutput = ProcessOutput(stdout: "", stderr: "", exitCode: 0), runError: Error? = nil) {
            self.output = output
            self.runError = runError
        }

        var calls: [StubCall] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try runWithTimeout(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
            try runWithTimeout(executable: executable, arguments: arguments, timeout: timeout)
        }

        private func runWithTimeout(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
            lock.lock()
            _calls.append(StubCall(executable: executable.path, arguments: arguments, timeout: timeout))
            lock.unlock()
            if let runError { throw runError }
            return output
        }
    }

    // MARK: - Fixtures

    struct GroupFixture {
        let len: Int64
        let hash: String
        let paths: [String]
    }

    private static func reportJSON(groups: [GroupFixture]) -> String {
        let groupsJSON = groups.map { g in
            let paths = g.paths.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"file_len":\#(g.len),"file_hash":"\#(g.hash)","files":[\#(paths)]}"#
        }.joined(separator: ",")
        return #"{"header":{"version":"0.34.0"},"groups":[\#(groupsJSON)]}"#
    }

    // MARK: - Invocation wiring

    @Test("invokes fclones once with `group --format json` and the scan roots")
    func invokesGroupFormatJson() async throws {
        let runner = StubRunner()
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/opt/homebrew/bin/fclones"),
            scanRoots: [a, b],
            runner: runner
        )

        _ = try await adapter.scan(progress: nil)

        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.executable == "/opt/homebrew/bin/fclones")
        #expect(runner.calls.first?.arguments == ["group", "--format", "json", a.path, b.path])
    }

    @Test("forwards the configured timeout to the runner")
    func forwardsTimeout() async throws {
        let runner = StubRunner()
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/a")],
            runner: runner,
            timeout: 42
        )

        _ = try await adapter.scan(progress: nil)

        #expect(runner.calls.first?.timeout == 42)
    }

    // MARK: - Result mapping

    @Test("each duplicate path becomes a review-default ScanResult with fileLen size")
    func mapsDuplicatesToScanResults() async throws {
        let json = Self.reportJSON(groups: [
            GroupFixture(len: 1024, hash: "abcdef1234567890", paths: ["/root/a.bin", "/root/b.bin"]),
        ])
        let runner = StubRunner(
            output: ProcessOutput(stdout: json, stderr: "", exitCode: 0)
        )
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/root")],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.safety == .review })
        #expect(results.allSatisfy { $0.size == 1024 })
        #expect(results.allSatisfy { $0.category == "duplicate_files" })
        #expect(results.allSatisfy { $0.source.name == "fclones" })
        #expect(results.allSatisfy { !$0.regenerates })
    }

    @Test("paths in the same group share a fclones_group tag; different groups get different tags")
    func groupTagsMatchGroupMembership() async throws {
        let json = Self.reportJSON(groups: [
            GroupFixture(len: 10, hash: "aaaa1111", paths: ["/a", "/b"]),
            GroupFixture(len: 20, hash: "bbbb2222", paths: ["/c", "/d"]),
        ])
        let runner = StubRunner(output: ProcessOutput(stdout: json, stderr: "", exitCode: 0))
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/root")],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 4)
        let tagsByPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.tags) })
        #expect(tagsByPath["/a"]?.contains("fclones_group_0") == true)
        #expect(tagsByPath["/b"]?.contains("fclones_group_0") == true)
        #expect(tagsByPath["/c"]?.contains("fclones_group_1") == true)
        #expect(tagsByPath["/d"]?.contains("fclones_group_1") == true)
        #expect(tagsByPath["/a"]?.contains("fclones_hash_aaaa1111") == true)
        #expect(tagsByPath["/c"]?.contains("fclones_hash_bbbb2222") == true)
    }

    @Test("duplicate paths across groups are reported only once")
    func deduplicatesPaths() async throws {
        // Defensive: fclones should never report the same path twice, but if it
        // does (e.g. via symlink into the same scan root) we must not emit
        // conflicting ScanResults.
        let json = Self.reportJSON(groups: [
            GroupFixture(len: 10, hash: "h1", paths: ["/shared", "/only-in-1"]),
            GroupFixture(len: 10, hash: "h2", paths: ["/shared", "/only-in-2"]),
        ])
        let runner = StubRunner(output: ProcessOutput(stdout: json, stderr: "", exitCode: 0))
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/root")],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        let paths = Set(results.map(\.path))
        #expect(paths == ["/shared", "/only-in-1", "/only-in-2"])
    }

    // MARK: - Error handling

    @Test("non-zero exit code records an error and returns no results")
    @MainActor
    func nonZeroExitIsReported() async throws {
        let runner = StubRunner(
            output: ProcessOutput(stdout: "", stderr: "permission denied", exitCode: 13)
        )
        let progress = ScanProgress()
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/a")],
            runner: runner
        )

        let results = try await adapter.scan(progress: progress)

        #expect(results.isEmpty)
        #expect(progress.errors.contains { $0.contains("exit 13") })
        #expect(progress.errors.contains { $0.contains("permission denied") })
    }

    @Test("runner failure (e.g. timeout) records an error and returns no results")
    @MainActor
    func runnerErrorIsReported() async throws {
        let runner = StubRunner(runError: ProcessRunnerError.timedOut(seconds: 30))
        let progress = ScanProgress()
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/a")],
            runner: runner
        )

        let results = try await adapter.scan(progress: progress)

        #expect(results.isEmpty)
        #expect(progress.errors.contains { $0.contains("fclones did not complete") })
    }

    @Test("unparseable output records an error and returns no results")
    @MainActor
    func parseFailureIsReported() async throws {
        let runner = StubRunner(
            output: ProcessOutput(stdout: "{garbage not json", stderr: "", exitCode: 0)
        )
        let progress = ScanProgress()
        let adapter = FclonesAdapter(
            binary: URL(fileURLWithPath: "/bin/fclones"),
            scanRoots: [URL(fileURLWithPath: "/a")],
            runner: runner
        )

        let results = try await adapter.scan(progress: progress)

        #expect(results.isEmpty)
        #expect(progress.errors.contains { $0.contains("parse failed") })
    }

    // MARK: - Trust defaults

    @Test("builtIn trust defaults map duplicates to review with moderate confidence")
    func builtInTrustDefaults() {
        let entry = FclonesTrustDefaults.builtIn.duplicate
        #expect(entry.safety == .review)
        #expect((40...80).contains(entry.confidence))
        #expect(!entry.explanation.isEmpty)
    }
}
