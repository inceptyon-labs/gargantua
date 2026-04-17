import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "FclonesAdapter")

/// Trust Layer defaults for fclones duplicate-file findings.
///
/// Per PRD §7, user-owned duplicate candidates never default to `.safe` —
/// fclones only confirms identical content, not which copy the user wants
/// to keep. Everything ships review-by-default with a moderate confidence.
public struct FclonesTrustDefaults: Sendable {
    public struct Entry: Sendable {
        public let safety: SafetyLevel
        public let confidence: Int
        public let explanation: String

        public init(safety: SafetyLevel, confidence: Int, explanation: String) {
            self.safety = safety
            self.confidence = confidence
            self.explanation = explanation
        }
    }

    public let duplicate: Entry

    public init(duplicate: Entry) {
        self.duplicate = duplicate
    }

    public static let builtIn = FclonesTrustDefaults(
        duplicate: Entry(
            safety: .review,
            confidence: 65,
            explanation: "Duplicate file content. Keep one, review the rest before removing."
        )
    )
}

/// Scan adapter backed by the `fclones` binary.
///
/// Runs a single `fclones group --format json <roots>` invocation inside a
/// wall-clock timeout, parses the JSON report, and maps every duplicate path
/// to a `ScanResult` with review-by-default safety. Each group gets a stable
/// `fclones_group_<id>` tag so UI layers can cluster duplicates.
public struct FclonesAdapter: ScanAdapter {
    public enum AdapterError: Error, LocalizedError, Sendable {
        case scanFailed(exitCode: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .scanFailed(let code, let stderr):
                "fclones group failed with exit code \(code): \(stderr)"
            }
        }
    }

    /// Default wall-clock timeout: 10 minutes. Large home directories can take
    /// a while; anything longer than this usually signals a hung process.
    public static let defaultTimeout: TimeInterval = 600

    private let binary: URL
    private let scanRoots: [URL]
    private let runner: ProcessRunner
    private let parser: FclonesOutputParser
    private let trustDefaults: FclonesTrustDefaults
    private let sourceAttribution: SourceAttribution
    private let timeout: TimeInterval

    public init(
        binary: URL,
        scanRoots: [URL],
        runner: ProcessRunner = DefaultProcessRunner(),
        parser: FclonesOutputParser = FclonesOutputParser(),
        trustDefaults: FclonesTrustDefaults = .builtIn,
        sourceAttribution: SourceAttribution = SourceAttribution(name: "fclones"),
        timeout: TimeInterval = FclonesAdapter.defaultTimeout
    ) {
        self.binary = binary
        self.scanRoots = scanRoots
        self.runner = runner
        self.parser = parser
        self.trustDefaults = trustDefaults
        self.sourceAttribution = sourceAttribution
        self.timeout = timeout
    }

    /// Convenience factory: resolve the binary via `FclonesBinaryResolver`.
    /// Throws if fclones can't be located.
    public static func autoDetect(
        scanRoots: [URL],
        resolver: FclonesBinaryResolver = FclonesBinaryResolver()
    ) throws -> FclonesAdapter {
        let binary = try resolver.resolve()
        return FclonesAdapter(binary: binary, scanRoots: scanRoots)
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        await progress?.start()
        let category = "duplicate_files"
        await progress?.update(
            fractionCompleted: 0,
            currentCategory: category,
            itemsFound: 0,
            reclaimableBytes: 0
        )

        let output: ProcessOutput
        do {
            output = try runner.run(
                executable: binary,
                arguments: arguments(),
                timeout: timeout
            )
        } catch {
            await progress?.recordError(
                "fclones did not complete: \(error.localizedDescription)"
            )
            await progress?.finish(itemsFound: 0)
            return []
        }

        guard output.exitCode == 0 else {
            await progress?.recordError(
                "fclones exit \(output.exitCode): \(output.stderr)"
            )
            await progress?.finish(itemsFound: 0)
            return []
        }

        let groups: [FclonesDuplicateGroup]
        do {
            groups = try parser.parse(output.stdout)
        } catch {
            await progress?.recordError(
                "fclones output parse failed: \(error.localizedDescription)"
            )
            await progress?.finish(itemsFound: 0)
            return []
        }

        var results: [ScanResult] = []
        var seenPaths: Set<String> = []
        var reclaimableBytes: Int64 = 0
        let entry = trustDefaults.duplicate

        for group in groups {
            let shortHash = String(group.fileHash.prefix(8))
            for path in group.paths where seenPaths.insert(path).inserted {
                let result = ScanResult(
                    id: "fclones-\(group.id)-\(results.count)",
                    name: path.split(separator: "/").last.map(String.init) ?? path,
                    path: path,
                    size: group.fileLen,
                    safety: entry.safety,
                    confidence: entry.confidence,
                    explanation: entry.explanation,
                    source: sourceAttribution,
                    lastAccessed: nil,
                    category: category,
                    tags: ["fclones_group_\(group.id)", "fclones_hash_\(shortHash)"],
                    regenerates: false,
                    regenerateCommand: nil
                )
                results.append(result)
                reclaimableBytes += group.fileLen
            }
        }

        await progress?.update(
            fractionCompleted: 1,
            currentCategory: category,
            itemsFound: results.count,
            reclaimableBytes: reclaimableBytes
        )
        await progress?.finish(itemsFound: results.count)
        logger.info(
            "FclonesAdapter: \(groups.count, privacy: .public) groups, \(results.count, privacy: .public) duplicate files"
        )
        return results
    }

    // MARK: - Private

    private func arguments() -> [String] {
        // `fclones group --format json <roots>` writes a JSON report to stdout.
        var args = ["group", "--format", "json"]
        for root in scanRoots { args.append(root.path) }
        return args
    }
}
