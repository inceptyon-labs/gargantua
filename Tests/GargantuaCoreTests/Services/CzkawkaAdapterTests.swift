import Foundation
import Testing
@testable import GargantuaCore

@Suite("CzkawkaAdapter")
struct CzkawkaAdapterTests {

    // MARK: - Stub runner

    struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
    }

    /// Deterministic `ProcessRunner` that records calls and replays canned
    /// stdout per subcommand. Defaults to exit 0 and empty stderr.
    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]

        init(outputs: [String: ProcessOutput]) {
            self.outputs = outputs
        }

        var calls: [StubCall] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            lock.lock()
            _calls.append(StubCall(executable: executable.path, arguments: arguments))
            lock.unlock()

            let subcommand = arguments.first ?? ""
            return outputs[subcommand] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    // MARK: - Fixture helpers

    private static func makeTempFile(byteCount: Int = 64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("target.bin")
        try Data(repeating: 0xAB, count: byteCount).write(to: url)
        return url
    }

    // MARK: - Invocation wiring

    @Test("invokes czkawka_cli once per configured category with scan roots")
    func invokesOncePerCategory() async throws {
        let runner = StubRunner(outputs: [:])
        let root = URL(fileURLWithPath: "/tmp/fake-root")
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/usr/local/bin/czkawka_cli"),
            categories: [.emptyFiles, .brokenSymlinks],
            scanRoots: [root],
            runner: runner
        )

        _ = try await adapter.scan(progress: nil)

        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].arguments == ["empty-files", "-d", root.path])
        #expect(runner.calls[1].arguments == ["symlinks", "-d", root.path])
        #expect(runner.calls.allSatisfy { $0.executable == "/usr/local/bin/czkawka_cli" })
    }

    @Test("multiple scan roots become repeated -d flags")
    func multipleScanRoots() async throws {
        let runner = StubRunner(outputs: [:])
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.emptyFiles],
            scanRoots: [a, b],
            runner: runner
        )

        _ = try await adapter.scan(progress: nil)

        #expect(runner.calls.first?.arguments == ["empty-files", "-d", a.path, "-d", b.path])
    }

    // MARK: - Result mapping

    @Test("empty-files findings get .safe safety and retain zero size")
    func emptyFilesMapSafe() async throws {
        // Czkawka reports zero-byte files, so `makeResult` must preserve size=0
        // rather than rejecting the finding.
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaEmptyTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let emptyFile = scratchDir.appendingPathComponent("zero.log")
        try Data().write(to: emptyFile)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let stdout = """
        Found 1 empty files.
        \(emptyFile.path)
        """
        let runner = StubRunner(outputs: [
            "empty-files": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.emptyFiles],
            scanRoots: [scratchDir],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.safety == .safe)
        #expect(results.first?.category == "empty_files")
        #expect(results.first?.size == 0)
        #expect(results.first?.source.name == "Czkawka")
    }

    @Test("big-files reported size flows through to ScanResult")
    func bigFilesReportedSize() async throws {
        let target = try Self.makeTempFile(byteCount: 1024)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        let stdout = """
        Found 1 biggest files.
        524288 \(target.path)
        """
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
        #expect(results.first?.size == 524_288)
        #expect(results.first?.safety == .review)
        #expect(results.first?.category == "big_files")
    }

    @Test("similar-images groupID becomes a czkawka_group tag")
    func similarImagesGroupTag() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaSimilarTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.jpg")
        let b = dir.appendingPathComponent("b.jpg")
        try Data(repeating: 1, count: 128).write(to: a)
        try Data(repeating: 2, count: 128).write(to: b)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stdout = """
        Found 2 similar images.
        \(a.path) - 1x1 - 128 B
        \(b.path) - 1x1 - 128 B
        """
        let runner = StubRunner(outputs: [
            "image": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.similarImages],
            scanRoots: [dir],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.safety == .review })
        #expect(results.allSatisfy { $0.tags == ["czkawka_group_0"] })
        #expect(results.allSatisfy { $0.category == "similar_images" })
    }

    @Test("paths deduplicate across categories")
    func dedupAcrossCategories() async throws {
        let target = try Self.makeTempFile(byteCount: 32)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        let stdout = "Found 1 file.\n\(target.path)"
        let runner = StubRunner(outputs: [
            "empty-files": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
            "temporary": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.emptyFiles, .temporaryFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner
        )

        let results = try await adapter.scan(progress: nil)

        // Only the first category's finding should remain; the temporary-files
        // pass would otherwise double-count the same path.
        #expect(results.count == 1)
        #expect(results.first?.category == "empty_files")
    }

    @Test("truncated output trims final partial line and records a warning")
    @MainActor
    func truncatedOutputTrimsPartialLine() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        // Third line is a deliberate mid-line slice: an absolute-looking
        // prefix of a path that does not exist. Without trimming, the parser
        // would accept it as a finding.
        let stdout =
            "Found 2 empty files.\n\(target.path)\n/tmp/partial-slice-that-does-not-exist-abc"
        let runner = StubRunner(outputs: [
            "empty-files": ProcessOutput(
                stdout: stdout, stderr: "", exitCode: 0, stdoutTruncated: true
            ),
        ])
        let progress = ScanProgress()
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.emptyFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner
        )

        let results = try await adapter.scan(progress: progress)

        #expect(results.count == 1, "sliced trailing line must not be parsed as a finding")
        #expect(results.first?.path == target.path)
        #expect(progress.errors.contains { $0.contains("exceeded") && $0.contains("cap") })
    }

    @Test("non-zero exit code is reported but does not abort sibling categories")
    @MainActor
    func continuesAfterSubcommandFailure() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "symlinks": ProcessOutput(stdout: "", stderr: "boom", exitCode: 7),
            "empty-files": ProcessOutput(
                stdout: "Found 1 empty files.\n\(target.path)",
                stderr: "",
                exitCode: 0
            ),
        ])
        let progress = ScanProgress()
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.brokenSymlinks, .emptyFiles],
            scanRoots: [target.deletingLastPathComponent()],
            runner: runner
        )

        let results = try await adapter.scan(progress: progress)

        #expect(results.count == 1)
        #expect(results.first?.category == "empty_files")
        #expect(progress.errors.contains { $0.contains("symlinks") && $0.contains("exit 7") })
    }

    // MARK: - Trust defaults

    @Test("builtIn trust defaults cover every category")
    func trustDefaultsCoverAllCategories() {
        let defaults = CzkawkaTrustDefaults.builtIn
        for category in CzkawkaCategory.allCases {
            let entry = defaults.entry(for: category)
            // Categories that are user-owned content default to review; the
            // trivially-disposable ones default to safe. Both are acceptable
            // here — we just want to guarantee an explicit mapping exists.
            let allowed: [SafetyLevel] = [.safe, .review]
            #expect(allowed.contains(entry.safety), "Missing or invalid default for \(category)")
        }
    }

    @Test("safe-default categories are all the zero-loss ones")
    func safeDefaultsAreZeroLossCategories() {
        let defaults = CzkawkaTrustDefaults.builtIn
        let safeCategories = CzkawkaCategory.allCases.filter {
            defaults.entry(for: $0).safety == .safe
        }
        #expect(Set(safeCategories) == [.emptyFiles, .emptyFolders, .brokenSymlinks, .temporaryFiles])
    }
}
