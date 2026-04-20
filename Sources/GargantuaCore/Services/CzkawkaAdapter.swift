import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "CzkawkaAdapter")

/// Trust Layer defaults for each Czkawka category.
///
/// Overridable at call time so profile wiring or future rules can remap (e.g.
/// downgrade similar-images to `.safe` under a "deep" profile). Defaults follow
/// the PRD §7 Trust Layer: only empty/broken/temp items default to `.safe`;
/// everything user-owned defaults to `.review`.
public struct CzkawkaTrustDefaults: Sendable {
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

    private let entries: [CzkawkaCategory: Entry]

    public init(entries: [CzkawkaCategory: Entry]) {
        self.entries = entries
    }

    public func entry(for category: CzkawkaCategory) -> Entry {
        entries[category] ?? Self.fallback
    }

    public static let fallback = Entry(
        safety: .review,
        confidence: 60,
        explanation: "Flagged by czkawka_cli. Review before removing."
    )

    public static let builtIn = CzkawkaTrustDefaults(entries: [
        .emptyFiles: Entry(
            safety: .safe,
            confidence: 98,
            explanation: "Zero-byte file. Safe to remove."
        ),
        .emptyFolders: Entry(
            safety: .safe,
            confidence: 98,
            explanation: "Empty directory. Safe to remove."
        ),
        .brokenSymlinks: Entry(
            safety: .safe,
            confidence: 95,
            explanation: "Symlink points at a missing target."
        ),
        .temporaryFiles: Entry(
            safety: .safe,
            confidence: 90,
            explanation: "Temporary file left over by an app or the system."
        ),
        .bigFiles: Entry(
            safety: .review,
            confidence: 50,
            explanation: "Unusually large file. Review before removing."
        ),
        .similarImages: Entry(
            safety: .review,
            confidence: 60,
            explanation: "Visually similar to other images. Keep one, discard duplicates."
        ),
        .similarVideos: Entry(
            safety: .review,
            confidence: 60,
            explanation: "Visually similar to other videos. Keep one, discard duplicates."
        ),
        .brokenFiles: Entry(
            safety: .review,
            confidence: 55,
            explanation: "File appears corrupt. Verify before removing."
        ),
    ])
}

/// Scan adapter backed by the `czkawka_cli` binary.
///
/// Each configured category becomes one `czkawka_cli` invocation scoped to the
/// adapter's scan roots. Findings are mapped to `ScanResult` with Trust Layer
/// safety defaults derived from `CzkawkaTrustDefaults`.
///
/// The adapter deliberately sidesteps the YAML rule layer — czkawka's
/// categories are orthogonal to rule-driven paths. `SafetyClassifier`
/// overrides can still be applied by the caller if needed.
public struct CzkawkaAdapter: ScanAdapter {
    public enum AdapterError: Error, LocalizedError, Sendable {
        case subcommandFailed(category: CzkawkaCategory, exitCode: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .subcommandFailed(let category, let code, let stderr):
                "czkawka_cli \(category.subcommand) failed with exit code \(code): \(stderr)"
            }
        }
    }

    /// Byte cap for captured czkawka_cli text output. Each subcommand
    /// enumerates candidate paths; a deep similar-image scan against a
    /// messy Photos library can easily produce megabytes of line-oriented
    /// output. 64 MiB keeps us well clear of pathological counts while
    /// bounding memory against a runaway subprocess. If this cap is hit
    /// the parser will operate on a truncated prefix and callers will be
    /// told via `ProcessOutput.stdoutTruncated`.
    static let scanCaptureLimit: Int = 64 * 1024 * 1024

    private let binary: URL
    private let categories: [CzkawkaCategory]
    private let scanRoots: [URL]
    private let runner: ProcessRunner
    private let parser: CzkawkaOutputParser
    private let trustDefaults: CzkawkaTrustDefaults
    private let sourceAttribution: SourceAttribution
    private let profile: CleanupProfile?
    private let classifier: SafetyClassifier

    public init(
        binary: URL,
        categories: [CzkawkaCategory],
        scanRoots: [URL],
        runner: ProcessRunner = DefaultProcessRunner(),
        parser: CzkawkaOutputParser = CzkawkaOutputParser(),
        trustDefaults: CzkawkaTrustDefaults = .builtIn,
        sourceAttribution: SourceAttribution = SourceAttribution(name: "Czkawka"),
        profile: CleanupProfile? = nil,
        classifier: SafetyClassifier = SafetyClassifier()
    ) {
        self.binary = binary
        self.categories = categories
        self.scanRoots = scanRoots
        self.runner = runner
        self.parser = parser
        self.trustDefaults = trustDefaults
        self.sourceAttribution = sourceAttribution
        self.profile = profile
        self.classifier = classifier
    }

    /// Convenience factory: resolve the binary via `CzkawkaBinaryResolver` and
    /// default to all categories. Throws if czkawka_cli can't be located.
    public static func autoDetect(
        categories: [CzkawkaCategory] = CzkawkaCategory.allCases,
        scanRoots: [URL],
        resolver: CzkawkaBinaryResolver = CzkawkaBinaryResolver(),
        profile: CleanupProfile? = nil,
        classifier: SafetyClassifier = SafetyClassifier()
    ) throws -> CzkawkaAdapter {
        let binary = try resolver.resolve()
        return CzkawkaAdapter(
            binary: binary,
            categories: categories,
            scanRoots: scanRoots,
            profile: profile,
            classifier: classifier
        )
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        await progress?.start()

        var results: [ScanResult] = []
        var seenPaths: Set<String> = []
        var reclaimableBytes: Int64 = 0
        let total = max(categories.count, 1)

        for (idx, category) in categories.enumerated() {
            await progress?.update(
                fractionCompleted: Double(idx) / Double(total),
                currentCategory: category.resultCategory,
                itemsFound: results.count,
                reclaimableBytes: reclaimableBytes
            )

            let output: ProcessOutput
            do {
                output = try runner.run(
                    executable: binary,
                    arguments: arguments(for: category),
                    timeout: nil,
                    maxCapturedBytes: Self.scanCaptureLimit
                )
            } catch {
                await progress?.recordError(
                    "czkawka_cli \(category.subcommand) did not launch: \(error.localizedDescription)"
                )
                continue
            }

            guard output.exitCode == 0 else {
                await progress?.recordError(
                    "czkawka_cli \(category.subcommand) exit \(output.exitCode): \(output.stderr)"
                )
                continue
            }

            let findings = parser.parse(output.stdout, category: category)
            logger.info(
                "Czkawka \(category.subcommand, privacy: .public): \(findings.count) findings"
            )

            var counter = 0
            for finding in findings where seenPaths.insert(finding.path).inserted {
                guard let result = makeResult(
                    finding: finding,
                    category: category,
                    counter: counter
                ) else { continue }
                counter += 1
                results.append(result)
                reclaimableBytes += result.size
            }
        }

        await progress?.finish(itemsFound: results.count)
        logger.info("CzkawkaAdapter: produced \(results.count) items")
        return results
    }

    // MARK: - Private

    private func arguments(for category: CzkawkaCategory) -> [String] {
        // czkawka_cli takes roots via `-d`, one flag per directory.
        var args = [category.subcommand]
        for root in scanRoots {
            args.append("-d")
            args.append(root.path)
        }
        return args
    }

    private func makeResult(
        finding: CzkawkaFinding,
        category: CzkawkaCategory,
        counter: Int
    ) -> ScanResult? {
        let size: Int64
        var lastAccessed: Date?

        if finding.reportedSize > 0 {
            size = finding.reportedSize
        } else {
            let (stSize, accessed) = statPath(finding.path)
            size = stSize
            lastAccessed = accessed
        }

        // Empty files/folders legitimately have zero size; everything else with
        // zero size usually means the file disappeared between scan and stat.
        if size == 0 && category != .emptyFiles && category != .emptyFolders {
            return nil
        }

        if lastAccessed == nil {
            lastAccessed = statPath(finding.path).accessed
        }

        let entry = trustDefaults.entry(for: category)
        let tags = finding.groupID.map { ["czkawka_group_\($0)"] } ?? []

        let base = ScanResult(
            id: "czkawka-\(category.rawValue)-\(counter)",
            name: finding.path.split(separator: "/").last.map(String.init) ?? finding.path,
            path: finding.path,
            size: size,
            safety: entry.safety,
            confidence: entry.confidence,
            explanation: entry.explanation,
            source: sourceAttribution,
            lastAccessed: lastAccessed,
            category: category.resultCategory,
            tags: tags,
            regenerates: false,
            regenerateCommand: nil
        )

        // Without a profile, czkawka findings keep their base Trust Layer
        // defaults (Phase 2 back-compat). With a profile, route through the
        // same classifier NativeScanAdapter uses so age-based overrides apply.
        //
        // Gate profile-level overrides by `profile.categories` to match
        // NativeScanAdapter semantics: a rule whose category isn't in the
        // profile doesn't run there at all, so its findings never get
        // reclassified. Here the categories are always scanned (File Health
        // shows them all), but we skip the classifier for results outside the
        // profile's scope so e.g. the developer profile's "age > 30d → safe"
        // doesn't silently downgrade user-owned big_files that the profile
        // wouldn't otherwise touch. Empty profile categories keeps the classic
        // "match everything" semantics.
        guard let profile else { return base }
        let categoryInScope = profile.categories.isEmpty
            || profile.categories.contains(category.resultCategory)
        guard categoryInScope else { return base }

        let classified = classifier.classify(result: base, profile: profile)
        return ScanResult(
            id: base.id,
            name: base.name,
            path: base.path,
            size: base.size,
            safety: classified.safety,
            confidence: classified.confidence,
            explanation: classified.explanation,
            source: base.source,
            lastAccessed: base.lastAccessed,
            category: base.category,
            tags: base.tags,
            regenerates: base.regenerates,
            regenerateCommand: base.regenerateCommand
        )
    }

    private func statPath(_ path: String) -> (size: Int64, accessed: Date?) {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        let size: Int64
        if isDirectory {
            size = DirectorySizeScanner.directorySize(at: path).totalSize
        } else {
            size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        let accessed = values?.contentAccessDate ?? values?.contentModificationDate
        return (size, accessed)
    }
}
