import Foundation
import Testing
@testable import GargantuaCore

extension CzkawkaAdapterTests {
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
            "temp": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
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

    @Test("exit 11 is treated as success (czkawka 9+ reports findings via exit 11)")
    @MainActor
    func exitElevenIsSuccess() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "empty-files": ProcessOutput(
                stdout: "Found 1 empty files.\n\(target.path)",
                stderr: "",
                exitCode: 11
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

        #expect(results.count == 1, "exit 11 should parse output, not discard it")
        #expect(results.first?.path == target.path)
        #expect(progress.errors.isEmpty, "exit 11 should not be recorded as an error")
    }
}
