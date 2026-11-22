import Foundation
import OSLog

#if canImport(AppKit)
    import AppKit
#endif

public struct DefaultProcessInventoryScanner: ProcessInventoryScanning {
    /// Wall-clock interval between the two snapshots used to derive CPU
    /// deltas. 500 ms is short enough that the scan feels instant and long
    /// enough that very-quiet processes still show non-zero CPU when they
    /// blip during the window.
    public static let defaultSampleIntervalNanoseconds: UInt64 = 500_000_000

    private let snapshotProvider: any ProcessSnapshotProviding
    private let launchdIndex: any LaunchdItemIndexing
    // Internal (not private) so peer-file extensions can read them.
    let resolver: any BinaryIdentityResolving
    let matcher: ProcessLaunchSourceMatcher
    let classifier: ProcessSafetyClassifier
    let fileExists: @Sendable (String) -> Bool
    private let userNameForUID: @Sendable (UInt32) -> String?
    private let foregroundPIDs: @Sendable () -> Set<Int32>
    private let sampleIntervalNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async -> Void

    /// Holds the last full-scan environment for `search` to reuse. Not an init
    /// parameter — an internal per-instance cache shared across all copies of
    /// this value type via its reference identity.
    private let searchEnvironmentCache = SearchEnvironmentCache()

    public init(
        snapshotProvider: any ProcessSnapshotProviding = DefaultProcessSnapshotProvider(),
        launchdIndex: any LaunchdItemIndexing = DefaultLaunchdItemIndex(),
        resolver: any BinaryIdentityResolving = DefaultBinaryIdentityResolver(
            signatureVerifier: DefaultCodeSignatureVerifier(includeNotarization: false)
        ),
        matcher: ProcessLaunchSourceMatcher = ProcessLaunchSourceMatcher(),
        classifier: ProcessSafetyClassifier = ProcessSafetyClassifier(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        userNameForUID: @escaping @Sendable (UInt32) -> String? = DefaultProcessSnapshotProvider.lookupUserName,
        foregroundPIDs: @escaping @Sendable () -> Set<Int32> = DefaultProcessInventoryScanner.detectForegroundPIDs,
        sampleIntervalNanoseconds: UInt64 = DefaultProcessInventoryScanner.defaultSampleIntervalNanoseconds,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.snapshotProvider = snapshotProvider
        self.launchdIndex = launchdIndex
        self.resolver = resolver
        self.matcher = matcher
        self.classifier = classifier
        self.fileExists = fileExists
        self.userNameForUID = userNameForUID
        self.foregroundPIDs = foregroundPIDs
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
        self.now = now
        self.sleep = sleep
    }

    /// Default foreground-PID detector. Bridges `NSWorkspace.runningApplications`
    /// to a `Set<Int32>` so the scanner can promote GUI apps from `userSession`
    /// to `foregroundApp`. Empty on non-AppKit platforms / sandboxed runs that
    /// can't see the workspace.
    @Sendable
    public static func detectForegroundPIDs() -> Set<Int32> {
        #if canImport(AppKit)
            var pids: Set<Int32> = []
            for app in NSWorkspace.shared.runningApplications {
                pids.insert(app.processIdentifier)
            }
            return pids
        #else
            return []
        #endif
    }

    public func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan {
        let env = await sampleEnvironment(delayNanoseconds: sampleIntervalNanoseconds)
        // Cache the freshly-sampled environment so a subsequent `search` reuses
        // its snapshot / launchd parse / CPU baseline instead of re-sampling.
        searchEnvironmentCache.store(env)
        let rankedSamples = rankSamples(
            env.secondSamples,
            firstByPID: env.firstByPID,
            metric: metric,
            topN: topN
        )
        return finishScan(rankedSamples, env: env, metric: metric, topN: topN)
    }

    /// Search the FULL process table (not just the top-N snapshot). Filters the
    /// raw samples by `query` over the cheap fields every process already
    /// carries — command, executable path, PID, parent name — then resolves
    /// identity/signatures only for the matches, capped at `limit`. This keeps
    /// the cost proportional to the number of matches, not the ~hundreds of
    /// running processes, so an idle daemon outside the top-N is still findable.
    public func search(
        query: String,
        metric: ProcessSortMetric,
        limit: Int
    ) async -> ProcessInventoryScan {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Reuse the environment captured by the last full scan — its snapshot,
        // launchd parse, and CPU baseline are everything matching needs, so a
        // keystroke pays neither the 500 ms delta window nor a launchd re-parse.
        // Fall back to a fresh, delay-free sample only if no scan has run yet.
        let env: SampleEnvironment
        if let cached = searchEnvironmentCache.load() {
            env = cached
        } else {
            env = await sampleEnvironment(delayNanoseconds: 0)
        }
        guard !needle.isEmpty else {
            return ProcessInventoryScan(
                items: [],
                totalProcessCount: env.secondSamples.count,
                sortedBy: metric,
                topN: nil,
                scannedAt: now()
            )
        }
        let matched = env.secondSamples.filter {
            Self.sampleMatches($0, needle: needle, parentNames: env.parentNames)
        }
        let ranked = rankSamples(matched, firstByPID: env.firstByPID, metric: metric, topN: limit)
        // topN nil: `ranked` is already capped at `limit`, and the result set is
        // "matches" rather than "top N of everything" — the view labels it as such.
        return finishScan(ranked, env: env, metric: metric, topN: nil)
    }

    /// Two CPU snapshots plus the launchd / foreground / parent-name context
    /// every item build needs. Shared by `scan` and `search` so both see the
    /// same process table and CPU baseline.
    private struct SampleEnvironment: Sendable {
        let firstByPID: [Int32: RawProcessSample]
        let secondSamples: [RawProcessSample]
        let launchdItems: [LaunchdItem]
        let foregroundSet: Set<Int32>
        let parentNames: [Int32: String]
    }

    /// Thread-safe holder for the most recent full-scan environment so a
    /// per-keystroke `search` can reuse its snapshot, launchd parse, and CPU
    /// baseline instead of re-sampling. A full `scan()` refreshes it.
    private final class SearchEnvironmentCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SampleEnvironment?
        func store(_ env: SampleEnvironment) {
            lock.lock(); stored = env; lock.unlock()
        }

        func load() -> SampleEnvironment? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// Samples the process table plus the launchd / foreground / parent-name
    /// context an item build needs. `delayNanoseconds` is the gap between the
    /// two CPU snapshots: the full scan uses the configured window; `search`
    /// passes 0 so its matching pass isn't stalled by an artificial delay.
    private func sampleEnvironment(delayNanoseconds: UInt64) async -> SampleEnvironment {
        // The resolver caches by binary path + mtime, so a replaced binary at
        // the same path re-resolves on its own. Keeping the cache warm across
        // passes is what makes per-keystroke `search()` cheap — it no longer
        // re-verifies signatures for binaries it already resolved this session.
        let firstSamples = snapshotProvider.snapshot()
        if delayNanoseconds > 0 {
            await sleep(delayNanoseconds)
        }
        let secondSamples = snapshotProvider.snapshot()

        // Build a quick lookup from PID → first sample so we can compute the
        // CPU delta without an O(n²) scan.
        var firstByPID: [Int32: RawProcessSample] = [:]
        firstByPID.reserveCapacity(firstSamples.count)
        for sample in firstSamples { firstByPID[sample.pid] = sample }

        return SampleEnvironment(
            firstByPID: firstByPID,
            secondSamples: secondSamples,
            launchdItems: launchdIndex.enumerate(),
            foregroundSet: foregroundPIDs(),
            // Resolve "what spawned this" from the FULL snapshot, before any
            // cap, so a child's parent name shows even when the parent itself
            // was ranked or filtered out of the displayed list.
            parentNames: Self.buildParentNames(secondSamples)
        )
    }

    /// Resolve identity/signature for the already-ranked sample slice and build
    /// the final, re-ranked `ProcessInventoryScan`. The expensive identity work
    /// runs only over `rankedSamples`, so callers control cost by how many
    /// samples they pass.
    private func finishScan(
        _ rankedSamples: [RawProcessSample],
        env: SampleEnvironment,
        metric: ProcessSortMetric,
        topN: Int?
    ) -> ProcessInventoryScan {
        // Within a single scan, most processes share the same UID (the
        // logged-in user), so caching the lookup avoids ~95% of redundant
        // `getpwuid_r` calls per scan.
        var userNameCache: [UInt32: String?] = [:]
        let resolveUser: (UInt32) -> String? = { uid in
            if let cached = userNameCache[uid] { return cached }
            let name = self.userNameForUID(uid)
            userNameCache[uid] = name
            return name
        }

        let context = ItemConstructionContext(
            launchdItems: env.launchdItems,
            launchdMatchIndex: LaunchdMatchIndex(env.launchdItems),
            foregroundPIDs: env.foregroundSet,
            resolveUser: resolveUser,
            parentNames: env.parentNames
        )

        var items: [ProcessItem] = []
        items.reserveCapacity(rankedSamples.count)
        for current in rankedSamples {
            let prior = comparablePrior(for: current, in: env.firstByPID)
            items.append(makeItem(prior: prior, current: current, context: context))
        }

        return ProcessInventoryScan(
            items: rank(items, by: metric),
            totalProcessCount: env.secondSamples.count,
            sortedBy: metric,
            topN: topN,
            scannedAt: now()
        )
    }

    /// Cheap, identity-free match used to pre-filter the full sample set before
    /// the expensive resolution pass. Matches command, executable path, PID,
    /// and the resolved parent name. `needle` must already be lowercased.
    static func sampleMatches(
        _ sample: RawProcessSample,
        needle: String,
        parentNames: [Int32: String]
    ) -> Bool {
        if sample.command.lowercased().contains(needle) { return true }
        if let path = sample.executablePath, path.lowercased().contains(needle) { return true }
        if String(sample.pid).contains(needle) { return true }
        if let parent = parentNames[sample.parentPID], parent.lowercased().contains(needle) {
            return true
        }
        return false
    }

    /// Map every sampled PID to a short display name for use as a child's
    /// "parent" label. Prefers the executable's basename (full, untruncated)
    /// over `pbi_comm` (capped at 16 bytes). PID 0/1 are labeled even if the
    /// snapshot couldn't sample them, since a reparented orphan points at
    /// launchd.
    static func buildParentNames(_ samples: [RawProcessSample]) -> [Int32: String] {
        var names: [Int32: String] = [:]
        names.reserveCapacity(samples.count + 2)
        for sample in samples {
            names[sample.pid] = parentName(for: sample)
        }
        if names[0] == nil { names[0] = "kernel_task" }
        if names[1] == nil { names[1] = "launchd" }
        return names
    }

    /// Best short name for a sample: executable basename, else command.
    static func parentName(for sample: RawProcessSample) -> String {
        if let path = sample.executablePath,
           let base = path.split(separator: "/").last,
           !base.isEmpty {
            return String(base)
        }
        return sample.command
    }

    /// Returns the prior sample only when it represents the SAME process
    /// instance as `current`. Two checks gate this:
    ///   1. Executable path matches (cheap recycled-PID guard).
    ///   2. Process start time matches — handles the case where the same
    ///      binary was respawned within the sample window (e.g. a daemon
    ///      managed by `KeepAlive`); without this, the new instance would
    ///      inherit a CPU baseline that predates its birth.
    func comparablePrior(
        for current: RawProcessSample,
        in firstByPID: [Int32: RawProcessSample]
    ) -> RawProcessSample? {
        guard let prior = firstByPID[current.pid] else { return nil }
        if prior.executablePath != current.executablePath { return nil }
        if prior.startTimeUnixSeconds != current.startTimeUnixSeconds { return nil }
        return prior
    }
}
