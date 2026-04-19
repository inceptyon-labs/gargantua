import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScanEngine")
struct ScanEngineTests {

    // MARK: - Test doubles

    /// Stub adapter that records invocation order and yields canned results.
    private final class RecordingAdapter: ScanAdapter, @unchecked Sendable {
        let tag: String
        let results: [ScanResult]
        let delay: TimeInterval
        let log: Log

        init(tag: String, results: [ScanResult], delay: TimeInterval = 0, log: Log) {
            self.tag = tag
            self.results = results
            self.delay = delay
            self.log = log
        }

        func scan(progress: ScanProgress?) async throws -> [ScanResult] {
            log.append(.start(tag: tag))
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            log.append(.finish(tag: tag))
            return results
        }
    }

    private final class ThrowingAdapter: ScanAdapter, @unchecked Sendable {
        let tag: String
        let error: Error
        let log: Log

        init(tag: String, error: Error, log: Log) {
            self.tag = tag
            self.error = error
            self.log = log
        }

        func scan(progress: ScanProgress?) async throws -> [ScanResult] {
            log.append(.start(tag: tag))
            throw error
        }
    }

    enum LogEvent: Equatable {
        case start(tag: String)
        case finish(tag: String)
    }

    /// Tracks overlapping calls so tests can detect concurrent execution.
    private final class Log: @unchecked Sendable {
        private let queue = DispatchQueue(label: "ScanEngineTests.Log")
        private var events: [LogEvent] = []

        func append(_ event: LogEvent) {
            queue.sync { events.append(event) }
        }

        var snapshot: [LogEvent] {
            queue.sync { events }
        }

        /// True if any adapter started before a previous adapter finished.
        var hasOverlap: Bool {
            queue.sync {
                var inFlight = 0
                for event in events {
                    switch event {
                    case .start:
                        inFlight += 1
                        if inFlight > 1 { return true }
                    case .finish:
                        inFlight -= 1
                    }
                }
                return false
            }
        }
    }

    private struct TestError: Error, Equatable {
        let tag: String
    }

    private static func makeResult(id: String) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: 1,
            safety: .review,
            confidence: 50,
            explanation: "test",
            source: SourceAttribution(name: "ScanEngineTests"),
            category: "test"
        )
    }

    // MARK: - Tests

    @Test("Empty adapter list returns no results without error")
    func emptyAdapterList() async throws {
        let engine = ScanEngine(adapters: [])
        let results = try await engine.scan(progress: nil)
        #expect(results.isEmpty)
    }

    @Test("Single adapter results pass through unchanged")
    func singleAdapter() async throws {
        let log = Log()
        let adapter = RecordingAdapter(
            tag: "A",
            results: [Self.makeResult(id: "a1"), Self.makeResult(id: "a2")],
            log: log
        )
        let engine = ScanEngine(adapters: [adapter])
        let results = try await engine.scan(progress: nil)
        #expect(results.map(\.id) == ["a1", "a2"])
    }

    @Test("Multiple adapters concatenate results in adapter order")
    func multipleAdaptersInOrder() async throws {
        let log = Log()
        let a = RecordingAdapter(tag: "A", results: [Self.makeResult(id: "a1")], log: log)
        let b = RecordingAdapter(
            tag: "B",
            results: [Self.makeResult(id: "b1"), Self.makeResult(id: "b2")],
            log: log
        )
        let c = RecordingAdapter(tag: "C", results: [Self.makeResult(id: "c1")], log: log)

        let engine = ScanEngine(adapters: [a, b, c])
        let results = try await engine.scan(progress: nil)

        #expect(results.map(\.id) == ["a1", "b1", "b2", "c1"])
    }

    @Test("Adapters run sequentially — no overlap per PRD §8.4")
    func sequentialExecution() async throws {
        let log = Log()
        let a = RecordingAdapter(
            tag: "A",
            results: [Self.makeResult(id: "a1")],
            delay: 0.05,
            log: log
        )
        let b = RecordingAdapter(
            tag: "B",
            results: [Self.makeResult(id: "b1")],
            delay: 0.05,
            log: log
        )
        let c = RecordingAdapter(
            tag: "C",
            results: [Self.makeResult(id: "c1")],
            delay: 0.05,
            log: log
        )

        let engine = ScanEngine(adapters: [a, b, c])
        _ = try await engine.scan(progress: nil)

        #expect(!log.hasOverlap, "Adapters must run sequentially, never in parallel")
        // Each adapter should start then finish before the next one starts.
        #expect(log.snapshot == [
            .start(tag: "A"), .finish(tag: "A"),
            .start(tag: "B"), .finish(tag: "B"),
            .start(tag: "C"), .finish(tag: "C"),
        ])
    }

    @Test("Throwing adapter propagates error and stops downstream adapters")
    func throwingAdapterStopsPipeline() async throws {
        let log = Log()
        let a = RecordingAdapter(tag: "A", results: [Self.makeResult(id: "a1")], log: log)
        let b = ThrowingAdapter(tag: "B", error: TestError(tag: "B"), log: log)
        let c = RecordingAdapter(tag: "C", results: [Self.makeResult(id: "c1")], log: log)

        let engine = ScanEngine(adapters: [a, b, c])

        await #expect(throws: TestError.self) {
            _ = try await engine.scan(progress: nil)
        }

        let events = log.snapshot
        // A fully executed; B started then threw; C never started.
        #expect(events.contains(.start(tag: "A")))
        #expect(events.contains(.finish(tag: "A")))
        #expect(events.contains(.start(tag: "B")))
        #expect(!events.contains(.start(tag: "C")))
    }

    @Test("Engine conforms to ScanAdapter so it can be nested")
    func engineConformsToScanAdapter() async throws {
        let log = Log()
        let inner = RecordingAdapter(tag: "inner", results: [Self.makeResult(id: "i1")], log: log)
        let innerEngine = ScanEngine(adapters: [inner])
        let outerEngine = ScanEngine(adapters: [innerEngine])

        let results = try await outerEngine.scan(progress: nil)
        #expect(results.map(\.id) == ["i1"])
    }

    @Test("Duplicate Finder defaults preserved — review safety carries through")
    func preservesReviewByDefault() async throws {
        let log = Log()
        let fclonesLike = RecordingAdapter(
            tag: "fclones",
            results: [
                ScanResult(
                    id: "fclones-0-0",
                    name: "dup.txt",
                    path: "/tmp/a/dup.txt",
                    size: 1024,
                    safety: .review,
                    confidence: 95,
                    explanation: "Duplicate file — identical content to another file.",
                    source: SourceAttribution(name: "fclones"),
                    category: "duplicate_files",
                    tags: ["fclones_group_0"]
                ),
            ],
            log: log
        )
        let engine = ScanEngine(adapters: [fclonesLike])
        let results = try await engine.scan(progress: nil)
        #expect(results.count == 1)
        #expect(results.first?.safety == .review)
    }
}
