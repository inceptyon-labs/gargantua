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

    /// Byte cap for captured fclones JSON output. fclones emits one object
    /// per duplicate group, so output scales with the number of duplicates,
    /// not the size of scanned data. 64 MiB headroom keeps us memory-safe
    /// against a runaway process while comfortably covering a messy home
    /// directory with hundreds of thousands of duplicate groups. If this
    /// cap is hit the JSON will be malformed and the parser will surface
    /// a scan error — which is the right outcome, since partial output
    /// would silently mis-report duplicate sets.
    static let scanCaptureLimit: Int = 64 * 1024 * 1024

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

        // fclones with no positional path arguments silently scans the current
        // working directory, which is never what the caller wants.
        guard !scanRoots.isEmpty else {
            await progress?.recordError("fclones scan requested without any scan roots")
            await progress?.finish(itemsFound: 0)
            return []
        }

        let output: ProcessOutput
        do {
            output = try runner.run(
                executable: binary,
                arguments: arguments(),
                timeout: timeout,
                maxCapturedBytes: Self.scanCaptureLimit
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

        let mapped = mapResults(groups: groups, category: category)
        await progress?.update(
            fractionCompleted: 1,
            currentCategory: category,
            itemsFound: mapped.results.count,
            reclaimableBytes: mapped.reclaimableBytes
        )
        let results = mapped.results
        await progress?.finish(itemsFound: results.count)
        logger.info(
            "FclonesAdapter: \(groups.count, privacy: .public) groups, \(results.count, privacy: .public) duplicate files"
        )
        return results
    }

    // MARK: - Private

    private struct MappedResults {
        let results: [ScanResult]
        let reclaimableBytes: Int64
    }

    private func mapResults(groups: [FclonesDuplicateGroup], category: String) -> MappedResults {
        var results: [ScanResult] = []
        var seenPaths: Set<String> = []
        var reclaimableBytes: Int64 = 0
        let entry = trustDefaults.duplicate

        for group in groups {
            let shortHash = String(group.fileHash.prefix(8))
            var emittedInGroup = 0
            for path in group.paths where seenPaths.insert(path).inserted {
                let result = ScanResult(
                    id: "fclones-\(group.id)-\(emittedInGroup)",
                    name: URL(fileURLWithPath: path).lastPathComponent,
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
                emittedInGroup += 1
            }
            // At least one copy must be kept, so reclaimable space for a group
            // of N identical files is (N - 1) × fileLen, not N × fileLen.
            // Overflow-safe: clamp rather than trap on a corrupt fclones report
            // that claims absurdly large fileLen values.
            if emittedInGroup >= 2 {
                let copies = Int64(emittedInGroup - 1)
                let (product, productOverflow) = copies.multipliedReportingOverflow(by: group.fileLen)
                let addend = productOverflow ? Int64.max : product
                let (sum, sumOverflow) = reclaimableBytes.addingReportingOverflow(addend)
                reclaimableBytes = sumOverflow ? Int64.max : sum
            }
        }

        return MappedResults(results: results, reclaimableBytes: reclaimableBytes)
    }

    private func arguments() -> [String] {
        // `fclones group --format json <roots>` writes a JSON report to stdout.
        var args = ["group", "--format", "json"]
        for root in scanRoots { args.append(root.path) }
        return args
    }
}
