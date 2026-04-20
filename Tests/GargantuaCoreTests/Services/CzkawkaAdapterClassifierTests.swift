import Darwin
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

    private static func makeTempFile(
        byteCount: Int = 64,
        name: String = "target.bin"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: byteCount).write(to: url)
        return url
    }

    /// Stamp access time AND modification time so `CzkawkaAdapter.statPath`
    /// reads a deterministic `lastAccessed` regardless of whether the host
    /// filesystem tracks atime. `FileManager.setAttributes` can't touch atime
    /// on macOS, so we go through `utimes(2)` directly.
    private static func setFileAge(_ url: URL, daysAgo: Double) throws {
        let whenEpoch = Date().timeIntervalSince1970 - daysAgo * 86400
        var times = [
            timeval(tv_sec: time_t(whenEpoch), tv_usec: 0), // atime
            timeval(tv_sec: time_t(whenEpoch), tv_usec: 0), // mtime
        ]
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return utimes(path, &times)
        }
        if status != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "utimes failed on \(url.path)"]
            )
        }
    }

    // MARK: - Baseline (no profile)

    @Test("without a profile, findings keep their base Trust Layer defaults")
    func noProfilePreservesBaseClassification() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setFileAge(target, daysAgo: 60)

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
        #expect(results.first?.confidence == 50)
    }

    // MARK: - In-scope categories are reclassified

    @Test("deep profile downgrades 7+ day similar_images to safe via SafetyClassifier")
    func deepProfileDowngradesAgedSimilarImages() async throws {
        // `.deep` includes `similar_images` in its categories AND defines a
        // profile-level `age > 7d → safe` override. An old image should land
        // on the override's safe classification, not the review default.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("old.jpg")
        try Data(repeating: 1, count: 128).write(to: image)
        try Self.setFileAge(image, daysAgo: 60)

        let stdout = """
        Found 1 similar images.
        \(image.path) - 1x1 - 128 B
        """
        let runner = StubRunner(outputs: [
            "image": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.similarImages],
            scanRoots: [dir],
            runner: runner,
            profile: .deep
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        let first = try #require(results.first)
        // The `lastAccessed` assertion makes this test actually prove the
        // production path — without it, a silent `nil` would still pass the
        // "stays at review" baseline test below.
        #expect(first.lastAccessed != nil)
        #expect(first.safety == .safe)
        #expect(first.confidence == 90)
        #expect(first.explanation.contains("Inactive for over a week."))
    }

    @Test("deep profile leaves recent similar_images at review")
    func deepProfileLeavesRecentSimilarImages() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CzkawkaClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("recent.jpg")
        try Data(repeating: 2, count: 128).write(to: image)
        try Self.setFileAge(image, daysAgo: 3)

        let stdout = """
        Found 1 similar images.
        \(image.path) - 1x1 - 128 B
        """
        let runner = StubRunner(outputs: [
            "image": ProcessOutput(stdout: stdout, stderr: "", exitCode: 0),
        ])
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.similarImages],
            scanRoots: [dir],
            runner: runner,
            profile: .deep
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.count == 1)
        #expect(results.first?.safety == .review)
    }

    // MARK: - Out-of-scope categories aren't reclassified

    @Test("profile category gating: big_files ignored under developer profile")
    func developerProfileIgnoresOutOfScopeCategory() async throws {
        // `.developer` does NOT include `big_files` in its categories, so even
        // an aged finding should keep the base review default — matches
        // NativeScanAdapter's "rules outside profile.categories don't run"
        // semantics, applied here at classification time instead of scan time.
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setFileAge(target, daysAgo: 120)

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
        #expect(results.first?.confidence == 50)
    }

    // MARK: - Light profile has no age overrides

    @Test("light profile (no age overrides) leaves base classifications intact")
    func lightProfilePreservesBaseClassification() async throws {
        let target = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try Self.setFileAge(target, daysAgo: 365)

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
