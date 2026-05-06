import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "PackageReceiptExpander")

/// One BOM-derived candidate path produced by expanding a package receipt.
///
/// `pkgID`, `pkgVersion`, and `installDate` carry the receipt's provenance so
/// the Trust Layer can render audit-grade explanations like
/// `"found because com.docker.docker (v4.30.0) installed it on 2025-12-04"`.
public struct PackageReceiptCandidate: Sendable, Equatable {
    /// Absolute path on disk.
    public let path: String

    /// Reverse-DNS package ID this path came from.
    public let pkgID: String

    /// Package version when readable from the receipt.
    public let pkgVersion: String?

    /// Install timestamp when readable from the receipt.
    public let installDate: Date?

    public init(
        path: String,
        pkgID: String,
        pkgVersion: String? = nil,
        installDate: Date? = nil
    ) {
        self.path = path
        self.pkgID = pkgID
        self.pkgVersion = pkgVersion
        self.installDate = installDate
    }
}

/// Errors specific to the receipt-expander pipeline.
public enum PackageReceiptExpanderError: Error, LocalizedError, Equatable {
    /// `pkgutil` exited non-zero. The exit code is preserved for diagnostics.
    case pkgutilFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .pkgutilFailed(let code, let stderr):
            "pkgutil exited \(code): \(stderr)"
        }
    }
}

/// Discovers candidate uninstall paths for an `AppInfo` by expanding
/// `pkgutil` package receipts whose IDs plausibly belong to the app.
///
/// **Receipts are evidence, not permission.** The expander returns *candidate*
/// paths — every candidate must still flow through the existing safety
/// classifier (`SafetyClassifier`, `protected_roots.yaml`, sensitive-data
/// preflight) before becoming actionable in an uninstall plan.
///
/// The expander does not delete, move, or modify anything on disk. It only
/// runs `pkgutil --pkgs`, `pkgutil --pkg-info <id>`, and `pkgutil --files <id>`
/// and parses their output.
///
/// **Caching**: the package list and per-package `(receipt, files)` are cached
/// per-instance so a single uninstall flow that hits two apps doesn't re-spawn
/// `pkgutil` for the entire receipt database. Caches are refilled on the
/// next `expand(...)` call after `clearCache()`; there is no time-based TTL.
public final class PackageReceiptExpander: @unchecked Sendable {
    public static let pkgutilPath = "/usr/sbin/pkgutil"

    private let runner: any ProcessRunner
    private let parser: PkgUtilOutputParser
    private let matcher: PackageMatcher
    private let pkgutilURL: URL
    private let timeout: TimeInterval
    private let fileInfoTimeout: TimeInterval

    private let cacheLock = NSLock()
    private var cachedPackageList: [String]?
    private var cachedReceipts: [String: PackageReceipt] = [:]
    private var cachedFiles: [String: [String]] = [:]

    public init(
        runner: any ProcessRunner = DefaultProcessRunner(),
        parser: PkgUtilOutputParser = PkgUtilOutputParser(),
        matcher: PackageMatcher = PackageMatcher(),
        pkgutilURL: URL = URL(fileURLWithPath: pkgutilPath),
        timeout: TimeInterval = 30,
        fileInfoTimeout: TimeInterval = 5
    ) {
        self.runner = runner
        self.parser = parser
        self.matcher = matcher
        self.pkgutilURL = pkgutilURL
        self.timeout = timeout
        // Path-oriented `--file-info` is a single inode lookup, not a full BOM
        // walk. The MCP explain provider runs synchronously on the transport
        // thread, so a hung pkgutil would block every other MCP request for
        // up to `timeout` seconds. Default to a tighter 5s budget here.
        self.fileInfoTimeout = fileInfoTimeout
    }

    /// Look up the package receipts that claim ownership of `path`.
    ///
    /// Wraps `pkgutil --file-info <path>`. The result is the list of
    /// receipts that claim the path; an empty list means either `pkgutil`
    /// has no receipts for the path or the call failed (the underlying
    /// error is logged but never thrown so explain-style callers can degrade
    /// gracefully when receipts are unavailable).
    ///
    /// Unlike `expand(for:)`, this lookup is **path-oriented** — it asks
    /// "which packages claim this path?" rather than "which packages match
    /// this app?". It is intended for explain-time provenance enrichment
    /// where a single path is the input.
    ///
    /// Results are not cached; receipt-by-path queries are expected to be
    /// one-shot per explain call, and `pkgutil --file-info` is fast.
    public func lookupReceipts(forPath path: String) -> [PackageReceipt] {
        guard !path.isEmpty else { return [] }

        let output: ProcessOutput
        do {
            output = try runner.run(
                executable: pkgutilURL,
                arguments: ["--file-info", path],
                timeout: fileInfoTimeout
            )
        } catch {
            logger.warning(
                "pkgutil --file-info failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }

        guard output.exitCode == 0 else {
            logger.debug(
                "pkgutil --file-info \(path, privacy: .public) exited \(output.exitCode, privacy: .public)"
            )
            return []
        }

        return parser.parseFileInfo(output.stdout)
    }

    /// Drop all cached `pkgutil` output. The next `expand(...)` will refetch.
    public func clearCache() {
        cacheLock.lock()
        cachedPackageList = nil
        cachedReceipts.removeAll()
        cachedFiles.removeAll()
        cacheLock.unlock()
    }

    /// Find all package receipts whose IDs plausibly match `app`, expand each
    /// receipt's BOM, and return the absolute candidate paths annotated with
    /// the receipt provenance.
    ///
    /// - Returns: One `PackageReceiptCandidate` per candidate file. Paths are
    ///   *not* deduplicated across receipts — a file claimed by two packages
    ///   shows up twice; the caller decides what to do (typically: keep the
    ///   first, or surface both as evidence).
    public func expand(for app: AppInfo) -> [PackageReceiptCandidate] {
        let allPackages: [String]
        do {
            allPackages = try loadPackageList()
        } catch {
            logger.warning("pkgutil --pkgs failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let matchedIDs = matcher.matches(packageIDs: allPackages, for: app)
        guard !matchedIDs.isEmpty else { return [] }

        var candidates: [PackageReceiptCandidate] = []
        for pkgID in matchedIDs {
            do {
                let (receipt, files) = try loadReceipt(pkgID: pkgID)
                guard let receipt else { continue }
                for entry in files {
                    let absolute = receipt.absolutePath(for: entry)
                    guard !absolute.isEmpty else { continue }
                    candidates.append(PackageReceiptCandidate(
                        path: absolute,
                        pkgID: receipt.pkgID,
                        pkgVersion: receipt.version,
                        installDate: receipt.installDate
                    ))
                }
            } catch {
                logger.warning(
                    "pkgutil expansion failed for \(pkgID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }
        return candidates
    }

    // MARK: - Internal

    private func loadPackageList() throws -> [String] {
        cacheLock.lock()
        if let cached = cachedPackageList {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let output = try runPkgutil(["--pkgs"])
        let list = parser.parsePackageList(output.stdout)

        cacheLock.lock()
        cachedPackageList = list
        cacheLock.unlock()
        return list
    }

    private func loadReceipt(pkgID: String) throws -> (PackageReceipt?, [String]) {
        cacheLock.lock()
        if let receipt = cachedReceipts[pkgID], let files = cachedFiles[pkgID] {
            cacheLock.unlock()
            return (receipt, files)
        }
        cacheLock.unlock()

        let infoOutput = try runPkgutil(["--pkg-info", pkgID])
        let receipt = parser.parsePackageInfo(infoOutput.stdout)

        let filesOutput = try runPkgutil(["--files", pkgID])
        let files = parser.parseFiles(filesOutput.stdout)

        cacheLock.lock()
        if let receipt {
            cachedReceipts[pkgID] = receipt
        }
        cachedFiles[pkgID] = files
        cacheLock.unlock()
        return (receipt, files)
    }

    private func runPkgutil(_ arguments: [String]) throws -> ProcessOutput {
        let output = try runner.run(executable: pkgutilURL, arguments: arguments, timeout: timeout)
        guard output.exitCode == 0 else {
            throw PackageReceiptExpanderError.pkgutilFailed(
                exitCode: output.exitCode,
                stderr: output.stderr
            )
        }
        return output
    }
}
