import Foundation
import Testing
@testable import GargantuaCore

@Suite("ProcessInventorySession")
@MainActor
struct ProcessInventorySessionTests {

    // MARK: - Fixtures

    private nonisolated static func makeItem(id: String, pid: Int32) -> ProcessItem {
        ProcessItem(
            id: id,
            pid: pid,
            parentPID: 1,
            startTimeUnixSeconds: 1_000,
            command: id,
            uid: 501,
            owningUser: "test",
            executablePath: "/usr/bin/\(id)",
            cpuFraction: 0.1,
            residentBytes: 1_024,
            identity: nil,
            launchSource: .unknown,
            launchConfidence: .heuristic,
            safety: .review,
            reasons: [],
            explanation: "test"
        )
    }

    private nonisolated static func makeScan(items: [ProcessItem]) -> ProcessInventoryScan {
        ProcessInventoryScan(
            items: items,
            totalProcessCount: items.count,
            sortedBy: .cpu,
            topN: nil,
            scannedAt: Date()
        )
    }

    /// Scripted scanner: pops queued scan/search results in order (holding
    /// the last one), and records the query/metric of each search it saw.
    private final class ScriptedScanner: ProcessInventoryScanning, @unchecked Sendable {
        private let lock = NSLock()
        private var scans: [ProcessInventoryScan]
        private var searches: [ProcessInventoryScan]
        private var searchCalls: [(query: String, metric: ProcessSortMetric)] = []

        init(scans: [ProcessInventoryScan], searches: [ProcessInventoryScan]) {
            self.scans = scans
            self.searches = searches
        }

        func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan {
            lock.withLock { scans.count > 1 ? scans.removeFirst() : scans[0] }
        }

        func search(query: String, metric: ProcessSortMetric, limit: Int) async -> ProcessInventoryScan {
            lock.withLock {
                searchCalls.append((query, metric))
                return searches.count > 1 ? searches.removeFirst() : searches[0]
            }
        }

        func recordedQueries() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return searchCalls.map(\.query)
        }

        func recordedMetrics() -> [ProcessSortMetric] {
            lock.lock()
            defer { lock.unlock() }
            return searchCalls.map(\.metric)
        }
    }

    /// Scanner whose search passes block until the test releases them by
    /// query, so overlap between passes can be sequenced deterministically.
    private actor SearchGate {
        private var waiters: [String: CheckedContinuation<ProcessInventoryScan, Never>] = [:]

        func wait(query: String) async -> ProcessInventoryScan {
            await withCheckedContinuation { waiters[query] = $0 }
        }

        func release(_ query: String, with scan: ProcessInventoryScan) {
            waiters.removeValue(forKey: query)?.resume(returning: scan)
        }

        func isWaiting(_ query: String) -> Bool {
            waiters[query] != nil
        }
    }

    private struct GatedScanner: ProcessInventoryScanning {
        let gate: SearchGate

        func scan(metric: ProcessSortMetric, topN: Int?) async -> ProcessInventoryScan {
            ProcessInventorySessionTests.makeScan(items: [])
        }

        func search(query: String, metric: ProcessSortMetric, limit: Int) async -> ProcessInventoryScan {
            await gate.wait(query: query)
        }
    }

    private func waitUntilWaiting(_ gate: SearchGate, _ query: String) async {
        while await !gate.isWaiting(query) { await Task.yield() }
    }

    private struct StubExecutor: ProcessActionExecuting {
        func stop(_ item: ProcessItem) async -> ProcessActionOutcome {
            ProcessActionOutcome(processID: item.id, action: .stop, succeeded: true)
        }

        func removeSource(_ item: ProcessItem) async -> ProcessActionOutcome {
            ProcessActionOutcome(processID: item.id, action: .removeSource, succeeded: false)
        }
    }

    // MARK: - Post-stop search refresh

    @Test("successful stop re-runs the active search so the dead row drops out")
    func stopRefreshesActiveSearch() async {
        let target = Self.makeItem(id: "target", pid: 42)
        let other = Self.makeItem(id: "other", pid: 43)
        let scanner = ScriptedScanner(
            scans: [Self.makeScan(items: [target, other]), Self.makeScan(items: [other])],
            searches: [Self.makeScan(items: [target]), Self.makeScan(items: [])]
        )
        let session = ProcessInventorySession(scanner: scanner, actionExecutor: StubExecutor())

        await session.scan(metric: .cpu, topN: nil)
        await session.search(query: "target", metric: .cpu)
        #expect(session.searchResults?.items.map(\.id) == ["target"])

        let outcome = await session.perform(.stop, on: target, metric: .cpu, topN: nil)

        #expect(outcome.succeeded)
        #expect(scanner.recordedQueries() == ["target", "target"])
        #expect(session.searchResults?.items.isEmpty == true)
        #expect(session.scan?.items.map(\.id) == ["other"])
    }

    @Test("post-stop refresh replays the latest search's metric, not the stop's")
    func stopRefreshUsesLatestSearchMetric() async {
        let target = Self.makeItem(id: "target", pid: 42)
        let scanner = ScriptedScanner(
            scans: [Self.makeScan(items: [target]), Self.makeScan(items: [])],
            searches: [Self.makeScan(items: [target]), Self.makeScan(items: [])]
        )
        let session = ProcessInventorySession(scanner: scanner, actionExecutor: StubExecutor())

        await session.scan(metric: .cpu, topN: nil)
        // The user re-sorted the active search to rss after the stop's
        // metric (cpu) was captured at action time.
        await session.search(query: "target", metric: .rss)

        _ = await session.perform(.stop, on: target, metric: .cpu, topN: nil)

        #expect(scanner.recordedMetrics() == [.rss, .rss])
    }

    @Test("stop without an active search does not run one")
    func stopWithoutSearchDoesNotSearch() async {
        let target = Self.makeItem(id: "target", pid: 42)
        let scanner = ScriptedScanner(
            scans: [Self.makeScan(items: [target]), Self.makeScan(items: [])],
            searches: [Self.makeScan(items: [])]
        )
        let session = ProcessInventorySession(scanner: scanner, actionExecutor: StubExecutor())

        await session.scan(metric: .cpu, topN: nil)
        _ = await session.perform(.stop, on: target, metric: .cpu, topN: nil)

        #expect(scanner.recordedQueries().isEmpty)
        #expect(session.searchResults == nil)
    }

    // MARK: - Superseded search passes

    @Test("a superseded search pass neither publishes nor clears the newer pass's spinner")
    func supersededSearchPassIsDropped() async {
        let gate = SearchGate()
        let session = ProcessInventorySession(scanner: GatedScanner(gate: gate), actionExecutor: nil)

        let oldPass = Task { await session.search(query: "old", metric: .cpu) }
        await waitUntilWaiting(gate, "old")
        let newPass = Task { await session.search(query: "new", metric: .cpu) }
        await waitUntilWaiting(gate, "new")

        // The old pass returns while the new one is still sampling: it must
        // not publish its stale result, and it must not clear the spinner
        // the new pass owns.
        await gate.release("old", with: Self.makeScan(items: [Self.makeItem(id: "stale", pid: 9)]))
        await oldPass.value

        #expect(session.searchResults == nil)
        #expect(session.isSearching)

        await gate.release("new", with: Self.makeScan(items: [Self.makeItem(id: "fresh", pid: 10)]))
        await newPass.value

        #expect(session.searchResults?.items.map(\.id) == ["fresh"])
        #expect(!session.isSearching)
    }

    @Test("clearSearch drops an in-flight pass's late result")
    func clearSearchDropsInFlightPass() async {
        let gate = SearchGate()
        let session = ProcessInventorySession(scanner: GatedScanner(gate: gate), actionExecutor: nil)

        let pass = Task { await session.search(query: "query", metric: .cpu) }
        await waitUntilWaiting(gate, "query")

        session.clearSearch()
        await gate.release("query", with: Self.makeScan(items: [Self.makeItem(id: "late", pid: 9)]))
        await pass.value

        #expect(session.searchResults == nil)
        #expect(!session.isSearching)
    }
}
