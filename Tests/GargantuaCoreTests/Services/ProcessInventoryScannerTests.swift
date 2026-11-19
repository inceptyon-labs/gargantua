import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessInventoryScanner")
// swiftlint:disable:next type_body_length
struct ProcessInventoryScannerTests {

    // MARK: - Stubs

    /// Two-shot snapshot stub: returns `first` on the initial `snapshot()`
    /// call, then `second` on every subsequent call. The scanner takes
    /// exactly two snapshots per scan; this matches that contract.
    private final class TwoShotProvider: ProcessSnapshotProviding, @unchecked Sendable {
        let first: [RawProcessSample]
        let second: [RawProcessSample]
        var calls = 0
        init(first: [RawProcessSample], second: [RawProcessSample]) {
            self.first = first
            self.second = second
        }
        func snapshot() -> [RawProcessSample] {
            calls += 1
            return calls == 1 ? first : second
        }
    }

    private struct StubLaunchdIndex: LaunchdItemIndexing {
        let items: [LaunchdItem]
        func enumerate() -> [LaunchdItem] { items }
    }

    private struct StubResolver: BinaryIdentityResolving {
        let map: [String: BinaryIdentity]
        func resolve(binaryPath: String) -> BinaryIdentity {
            map[binaryPath] ?? BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
        }
    }

    // MARK: - Helpers

    private func sample(
        pid: Int32,
        parent: Int32 = 1,
        uid: UInt32 = 501,
        command: String,
        path: String?,
        cpuTime: UInt64,
        rss: UInt64 = 0,
        startTime: UInt64 = 1_699_000_000,
        at offsetSeconds: TimeInterval = 0
    ) -> RawProcessSample {
        RawProcessSample(
            pid: pid,
            parentPID: parent,
            uid: uid,
            command: command,
            executablePath: path,
            startTimeUnixSeconds: startTime,
            cpuTimeNanoseconds: cpuTime,
            residentBytes: rss,
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds)
        )
    }

    private func makeScanner(
        first: [RawProcessSample],
        second: [RawProcessSample],
        launchd: [LaunchdItem] = [],
        resolverMap: [String: BinaryIdentity] = [:],
        existingFiles: Set<String> = [],
        foregroundPIDs: Set<Int32> = []
    ) -> DefaultProcessInventoryScanner {
        DefaultProcessInventoryScanner(
            snapshotProvider: TwoShotProvider(first: first, second: second),
            launchdIndex: StubLaunchdIndex(items: launchd),
            resolver: StubResolver(map: resolverMap),
            matcher: ProcessLaunchSourceMatcher(),
            classifier: ProcessSafetyClassifier(),
            fileExists: { existingFiles.contains($0) },
            userNameForUID: { uid in uid == 501 ? "alice" : nil },
            foregroundPIDs: { foregroundPIDs },
            sampleIntervalNanoseconds: 0,
            now: { Date(timeIntervalSince1970: 1_700_000_001) },
            sleep: { _ in }
        )
    }

    // MARK: - Tests

    @Test("CPU delta is computed across the two snapshots")
    func cpuDelta() async throws {
        // Process used 0.5s of CPU over a 1s wall-clock window → 50% of one core.
        let first = sample(pid: 100, command: "worker", path: "/usr/local/bin/worker", cpuTime: 0, at: 0)
        let second = sample(pid: 100, command: "worker", path: "/usr/local/bin/worker", cpuTime: 500_000_000, at: 1)
        let scanner = makeScanner(first: [first], second: [second])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try #require(scan.items.first)
        #expect(abs(item.cpuFraction - 0.5) < 0.001)
    }

    @Test("CPU is zero when the prior sample is missing (newly-spawned process)")
    func cpuZeroWithoutPrior() async {
        let second = sample(pid: 200, command: "fresh", path: "/usr/bin/fresh", cpuTime: 1_000_000_000, at: 1)
        let scanner = makeScanner(first: [], second: [second])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first?.cpuFraction == 0)
    }

    @Test("Recycled PID with different exec path drops the prior baseline")
    func recycledPIDDoesNotInheritCPU() async throws {
        // Prior sample at pid 300 was a different binary; second snapshot's
        // CPU time would be artificially huge if we naively diffed. Verify we
        // detect the path mismatch and report 0% rather than a wild number.
        let first = sample(pid: 300, command: "old", path: "/old/path", cpuTime: 100, at: 0)
        let second = sample(pid: 300, command: "new", path: "/new/path", cpuTime: 1_000_000_000, at: 1)
        let scanner = makeScanner(first: [first], second: [second])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try #require(scan.items.first)
        #expect(item.cpuFraction == 0)
        #expect(item.executablePath == "/new/path")
    }

    @Test("Sort by CPU descending puts highest CPU first")
    func sortByCPU() async {
        let firstA = sample(pid: 1, command: "a", path: "/a", cpuTime: 0, at: 0)
        let secondA = sample(pid: 1, command: "a", path: "/a", cpuTime: 100_000_000, at: 1) // 10%
        let firstB = sample(pid: 2, command: "b", path: "/b", cpuTime: 0, at: 0)
        let secondB = sample(pid: 2, command: "b", path: "/b", cpuTime: 800_000_000, at: 1) // 80%
        let scanner = makeScanner(first: [firstA, firstB], second: [secondA, secondB])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.map(\.command) == ["b", "a"])
    }

    @Test("Sort by RSS descending puts highest memory first")
    func sortByRSS() async {
        let s1 = sample(pid: 1, command: "small", path: "/s", cpuTime: 0, rss: 1_000_000, at: 1)
        let s2 = sample(pid: 2, command: "large", path: "/l", cpuTime: 0, rss: 100_000_000, at: 1)
        let scanner = makeScanner(first: [], second: [s1, s2])

        let scan = await scanner.scan(metric: .rss, topN: nil)
        #expect(scan.items.map(\.command) == ["large", "small"])
    }

    @Test("topN caps the resolved item population")
    func topNCapsResolvedPopulation() async {
        let samples = (1 ... 100).map { i in
            sample(pid: Int32(i), command: "p\(i)", path: "/p\(i)", cpuTime: UInt64(i) * 1_000_000, at: 1)
        }
        let scanner = makeScanner(first: [], second: samples)
        let scan = await scanner.scan(metric: .cpu, topN: 10)
        #expect(scan.items.count == 10)
        #expect(scan.totalProcessCount == 100)
        #expect(scan.topN == 10)
    }

    @Test("topN limits identity resolution")
    func topNLimitsIdentityResolution() async {
        final class CountingResolver: BinaryIdentityResolving, @unchecked Sendable {
            var resolved: [String] = []
            func resolve(binaryPath: String) -> BinaryIdentity {
                resolved.append(binaryPath)
                return BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
            }
            func clearCache() {}
        }

        let samples = (1 ... 100).map { i in
            sample(
                pid: Int32(i),
                command: "p\(i)",
                path: "/p\(i)",
                cpuTime: 0,
                rss: UInt64(i) * 1_000_000,
                at: 1
            )
        }
        let resolver = CountingResolver()
        let scanner = DefaultProcessInventoryScanner(
            snapshotProvider: TwoShotProvider(first: [], second: samples),
            launchdIndex: StubLaunchdIndex(items: []),
            resolver: resolver,
            matcher: ProcessLaunchSourceMatcher(),
            classifier: ProcessSafetyClassifier(),
            fileExists: { _ in true },
            userNameForUID: { _ in nil },
            foregroundPIDs: { [] },
            sampleIntervalNanoseconds: 0,
            now: { Date() },
            sleep: { _ in }
        )

        let scan = await scanner.scan(metric: .rss, topN: 10)

        #expect(scan.items.count == 10)
        #expect(scan.totalProcessCount == 100)
        #expect(resolver.resolved.count == 10)
    }

    @Test("Scanner keeps the resolver cache warm across passes (no per-pass clear)")
    func resolverCacheNotClearedPerPass() async {
        // The resolver now self-invalidates by path + mtime, so the scanner must
        // NOT wipe it each pass — keeping it warm is what makes per-keystroke
        // search cheap. A replaced binary re-resolves on its own via mtime.
        final class CountingResolver: BinaryIdentityResolving, @unchecked Sendable {
            var clearCount = 0
            func resolve(binaryPath: String) -> BinaryIdentity {
                BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
            }
            func clearCache() { clearCount += 1 }
        }
        let counting = CountingResolver()
        let scanner = DefaultProcessInventoryScanner(
            snapshotProvider: TwoShotProvider(first: [], second: []),
            launchdIndex: StubLaunchdIndex(items: []),
            resolver: counting,
            matcher: ProcessLaunchSourceMatcher(),
            classifier: ProcessSafetyClassifier(),
            fileExists: { _ in true },
            userNameForUID: { _ in nil },
            foregroundPIDs: { [] },
            sampleIntervalNanoseconds: 0,
            now: { Date() },
            sleep: { _ in }
        )

        _ = await scanner.scan(metric: .cpu, topN: nil)
        _ = await scanner.scan(metric: .cpu, topN: nil)
        #expect(counting.clearCount == 0)
    }

    @Test("Launchd-matched process surfaces its plist path through launchSource")
    func launchSourcePropagated() async throws {
        let plist = LaunchdPlist(label: "com.acme.helper", program: "/Applications/Acme.app/Contents/MacOS/helper")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/Users/me/Library/LaunchAgents/acme.plist", plist: plist)
        let s = sample(pid: 42, parent: 1, command: "helper", path: "/Applications/Acme.app/Contents/MacOS/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [s],
            launchd: [item],
            existingFiles: ["/Applications/Acme.app/Contents/MacOS/helper"]
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let process = try #require(scan.items.first)
        #expect(process.launchConfidence == .exact)
        #expect(process.launchSource.plistPath == "/Users/me/Library/LaunchAgents/acme.plist")
    }

    @Test("Orphaned launchd source is detected when plist's binary is missing")
    func orphanedDetection() async throws {
        let plist = LaunchdPlist(label: "com.zombie.helper", program: "/Applications/Gone.app/Contents/MacOS/helper")
        let item = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: plist)
        let s = sample(pid: 77, command: "helper", path: "/Applications/Gone.app/Contents/MacOS/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [s],
            launchd: [item],
            existingFiles: [] // plist's binary missing
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let process = try #require(scan.items.first)
        #expect(process.safety == .safe)
        #expect(process.reasons.contains(.orphaned) == true)
    }

    @Test("ID is stable across rescans for the same pid + binary")
    func stableIDAcrossScans() async {
        let s = sample(pid: 99, command: "stable", path: "/usr/bin/stable", cpuTime: 0, at: 1)
        let scanner = makeScanner(first: [], second: [s])

        let firstID = (await scanner.scan(metric: .cpu, topN: nil)).items.first?.id
        let secondID = (await scanner.scan(metric: .cpu, topN: nil)).items.first?.id
        #expect(firstID != nil)
        #expect(firstID == secondID)
    }

    @Test("Owning user resolves via the injected lookup, falling back to UID")
    func userLookup() async {
        let resolved = sample(pid: 1, uid: 501, command: "alice-proc", path: "/p", cpuTime: 0, at: 1)
        let unresolved = sample(pid: 2, uid: 6502, command: "unknown-proc", path: "/q", cpuTime: 0, at: 1)
        let scanner = makeScanner(first: [], second: [resolved, unresolved])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first(where: { $0.command == "alice-proc" })?.owningUser == "alice")
        #expect(scan.items.first(where: { $0.command == "unknown-proc" })?.owningUser == "6502")
    }

    @Test("Total process count reflects the live snapshot with a capped item list")
    func totalCountWithCappedItemList() async {
        let samples = (1 ... 5).map { i in
            sample(pid: Int32(i), command: "p\(i)", path: "/p\(i)", cpuTime: 0, rss: UInt64(i) * 1_000_000, at: 1)
        }
        let scanner = makeScanner(first: [], second: samples)
        let scan = await scanner.scan(metric: .rss, topN: 2)
        #expect(scan.totalProcessCount == 5)
        #expect(scan.items.count == 2)
        #expect(scan.topN == 2)
    }

    @Test("Recycled PID with same exec path but different start time drops baseline")
    func recycledPIDSameBinaryDifferentStartTime() async {
        // Same PID, same exec path, but startTime moved → it's a respawned
        // process; the new instance must not inherit the old CPU baseline.
        let prior = sample(pid: 400, command: "helper", path: "/h", cpuTime: 100, startTime: 1_699_000_000, at: 0)
        let current = sample(pid: 400, command: "helper", path: "/h", cpuTime: 1_000_000_000, startTime: 1_699_000_500, at: 1)
        let scanner = makeScanner(first: [prior], second: [current])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first?.cpuFraction == 0)
    }

    @Test("Heuristic launchd match does NOT trigger orphaned reason")
    func heuristicMatchSuppressesOrphan() async throws {
        // Process command shares a name with an unrelated stale plist whose
        // executable is missing. Without the confidence guard the scanner
        // would falsely tag this as orphaned/safe.
        let stalePlist = LaunchdPlist(label: "com.unrelated.helper", program: "/Applications/Gone.app/Contents/MacOS/helper")
        let stale = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: stalePlist)
        let current = sample(pid: 50, parent: 1, command: "helper", path: "/usr/local/bin/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [current],
            launchd: [stale],
            existingFiles: ["/usr/local/bin/helper"] // process's own binary exists, plist's doesn't
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try #require(scan.items.first)
        // Heuristic match is fine, but the orphan signal must not fire.
        #expect(item.launchConfidence == .heuristic)
        #expect(item.reasons.contains(.orphaned) == false)
        #expect(item.safety != .safe)
    }

    @Test("Heuristic launchd match with known vendor stays at review (not safe)")
    func heuristicKnownVendorStaysReview() async throws {
        // Known vendor + label-only heuristic match should NOT promote to
        // safe; only exact/path matches earn that.
        let stalePlist = LaunchdPlist(label: "com.acme.tool")
        let stale = LaunchdItem(domain: .userAgent, plistPath: "/p.plist", plist: stalePlist)
        let identity = BinaryIdentity(
            binaryPath: "/usr/local/bin/tool",
            bundlePath: "/Applications/Acme.app",
            vendor: .thirdPartyKnown,
            vendorDisplayName: "Acme"
        )
        let current = sample(pid: 60, parent: 1, command: "tool", path: "/usr/local/bin/tool", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [current],
            launchd: [stale],
            resolverMap: ["/usr/local/bin/tool": identity],
            existingFiles: ["/usr/local/bin/tool"]
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try #require(scan.items.first)
        #expect(item.launchConfidence == .heuristic)
        #expect(item.safety == .review)
    }

    @Test("Foreground PIDs are promoted from userSession to foregroundApp")
    func foregroundPromotion() async throws {
        let current = sample(pid: 999, parent: 1, command: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", cpuTime: 0, at: 1)
        let scanner = makeScanner(
            first: [],
            second: [current],
            foregroundPIDs: [999]
        )

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        let item = try #require(scan.items.first)
        #expect(item.launchSource == .foregroundApp)
        #expect(item.reasons.contains(.foregroundApp) == true)
    }

    @Test("Parent name resolves to the spawner even when the parent is ranked out of the list")
    func parentNameResolvesAcrossCap() async throws {
        // zsh (tiny) spawns perl5.34 (large). With topN=1 only the child
        // survives the cap, but its parentName still resolves from the full
        // snapshot — answering "what spawned this?" without the parent on screen.
        let parent = sample(pid: 500, parent: 1, command: "zsh", path: "/bin/zsh", cpuTime: 0, rss: 1_000, at: 1)
        let child = sample(pid: 600, parent: 500, command: "perl5.34", path: "/usr/bin/perl5.34", cpuTime: 0, rss: 50_000_000, at: 1)
        let scanner = makeScanner(first: [], second: [parent, child])

        let scan = await scanner.scan(metric: .rss, topN: 1)
        let item = try #require(scan.items.first)
        #expect(item.command == "perl5.34")
        #expect(item.parentName == "zsh")
    }

    @Test("A process parented by launchd resolves its parent name to launchd")
    func parentNameLaunchdFallback() async {
        // PID 1 isn't in the snapshot, but a reparented/launchd-rooted process
        // should still name its parent rather than show a bare number.
        let s = sample(pid: 700, parent: 1, command: "helper", path: "/usr/bin/helper", cpuTime: 0, at: 1)
        let scanner = makeScanner(first: [], second: [s])

        let scan = await scanner.scan(metric: .cpu, topN: nil)
        #expect(scan.items.first?.parentName == "launchd")
    }

    @Test("parentName prefers the executable basename over the truncated command")
    func parentNameBasenamePreference() {
        let withPath = sample(pid: 1, command: "trunc", path: "/opt/homebrew/bin/python3.12", cpuTime: 0)
        #expect(DefaultProcessInventoryScanner.parentName(for: withPath) == "python3.12")
        let noPath = sample(pid: 2, command: "kernel_task", path: nil, cpuTime: 0)
        #expect(DefaultProcessInventoryScanner.parentName(for: noPath) == "kernel_task")
    }

    // MARK: - Search

    @Test("search finds a low-resource process that the top-N snapshot would hide")
    func searchFindsBelowCap() async {
        // 60 busy processes dominate; perl is idle and would never make the
        // top-50 cap, but a full-table search must still surface it.
        var samples = (1 ... 60).map { i in
            sample(pid: Int32(i), command: "busy\(i)", path: "/b\(i)", cpuTime: 0, rss: UInt64(i) * 1_000_000, at: 1)
        }
        samples.append(sample(pid: 9000, command: "perl5.34", path: "/usr/bin/perl5.34", cpuTime: 0, rss: 1, at: 1))
        let scanner = makeScanner(first: [], second: samples)

        // A normal capped scan excludes the idle process…
        let snapshot = await scanner.scan(metric: .rss, topN: 50)
        #expect(!snapshot.items.contains { $0.command == "perl5.34" })

        // …but search finds it.
        let results = await scanner.search(query: "perl", metric: .rss, limit: 200)
        #expect(results.items.map(\.command) == ["perl5.34"])
        #expect(results.totalProcessCount == 61)
    }

    @Test("search matches command, path, PID, and parent name")
    func searchMatchFields() async {
        let parent = sample(pid: 400, parent: 1, command: "node", path: "/usr/local/bin/node", cpuTime: 0, rss: 5, at: 1)
        let child = sample(pid: 8080, parent: 400, command: "esbuild", path: "/tmp/xyz/esbuild", cpuTime: 0, rss: 5, at: 1)
        let scanner = makeScanner(first: [], second: [parent, child])

        let byCommand = await scanner.search(query: "esbuild", metric: .rss, limit: 200)
        #expect(byCommand.items.map(\.command) == ["esbuild"])

        let byPath = await scanner.search(query: "/tmp/xyz", metric: .rss, limit: 200)
        #expect(byPath.items.map(\.command) == ["esbuild"])

        let byPID = await scanner.search(query: "8080", metric: .rss, limit: 200)
        #expect(byPID.items.map(\.command) == ["esbuild"])

        // "node" matches node's own command AND esbuild via its parent name.
        let byParent = await scanner.search(query: "node", metric: .rss, limit: 200)
        #expect(Set(byParent.items.map(\.command)) == ["esbuild", "node"])
    }

    @Test("search caps results at the limit")
    func searchCapsAtLimit() async {
        let samples = (1 ... 50).map { i in
            sample(pid: Int32(i), command: "daemon\(i)", path: "/d\(i)", cpuTime: 0, rss: UInt64(i), at: 1)
        }
        let scanner = makeScanner(first: [], second: samples)
        let results = await scanner.search(query: "daemon", metric: .rss, limit: 10)
        #expect(results.items.count == 10)
    }

    @Test("search with a blank query returns no matches")
    func searchBlankQuery() async {
        let s = sample(pid: 1, command: "anything", path: "/a", cpuTime: 0, at: 1)
        let scanner = makeScanner(first: [], second: [s])
        let results = await scanner.search(query: "   ", metric: .cpu, limit: 200)
        #expect(results.items.isEmpty)
    }

    @Test("Item ID includes start time so respawned same-binary PIDs are distinct")
    func idIncludesStartTime() async {
        let s1 = sample(pid: 77, command: "x", path: "/x", cpuTime: 0, startTime: 1_000, at: 1)
        let s2 = sample(pid: 77, command: "x", path: "/x", cpuTime: 0, startTime: 2_000, at: 1)

        let scannerA = makeScanner(first: [], second: [s1])
        let scannerB = makeScanner(first: [], second: [s2])

        let idA = (await scannerA.scan(metric: .cpu, topN: nil)).items.first?.id
        let idB = (await scannerB.scan(metric: .cpu, topN: nil)).items.first?.id
        #expect(idA != nil)
        #expect(idB != nil)
        #expect(idA != idB)
    }
}
