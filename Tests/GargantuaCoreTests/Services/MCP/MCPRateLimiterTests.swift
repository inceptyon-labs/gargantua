import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP rate limiter")
struct MCPRateLimiterTests {

    // MARK: Fixtures

    /// Virtual clock so tests never rely on wall-clock sleeps.
    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
            self.current = start
        }
        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        func advance(seconds: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private func makeLimiter(
        window: TimeInterval = 60,
        maxOps: Int = 1,
        clock: VirtualClock = VirtualClock()
    ) -> (MCPRateLimiter, VirtualClock) {
        let limiter = MCPRateLimiter(
            window: window,
            maxOps: maxOps,
            clock: { [weak clock] in clock?.now() ?? Date() }
        )
        return (limiter, clock)
    }

    // MARK: Allow / reject within window

    @Test("first call within a fresh window is allowed")
    func firstCallAllowed() {
        let (limiter, _) = makeLimiter()
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
    }

    @Test("second call within the same window is rejected with a positive retryAfter")
    func secondCallRejected() {
        let (limiter, clock) = makeLimiter()
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        clock.advance(seconds: 10)
        let result = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        guard case .rejected(let retryAfter) = result else {
            Issue.record("expected rejected, got \(result)")
            return
        }
        // First event was at t+0, window is 60s; at t+10s retry is 50s away.
        #expect(retryAfter > 49 && retryAfter <= 50)
    }

    @Test("rejected result does not consume budget — client can retry at window end")
    func rejectedDoesNotConsumeBudget() {
        let (limiter, clock) = makeLimiter()
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        clock.advance(seconds: 5)
        // Multiple rejects in the same window must all still be rejected,
        // not compound additional budget debits that would push retryAfter
        // even further into the future.
        let first = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        let second = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        guard case .rejected(let retryFirst) = first,
              case .rejected(let retrySecond) = second else {
            Issue.record("expected both to be rejected")
            return
        }
        // Both rejections reference the same original event; retrySecond
        // should equal retryFirst within a small margin (no clock advance
        // between them).
        #expect(abs(retryFirst - retrySecond) < 0.001)
    }

    // MARK: Recovery after window

    @Test("operation is allowed once the window elapses")
    func allowedAfterWindow() {
        let (limiter, clock) = makeLimiter(window: 60)
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        clock.advance(seconds: 59)
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") != .allowed)
        clock.advance(seconds: 2) // total: 61s after first op
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
    }

    @Test("oldest event ages out; new op admitted even under sustained traffic")
    func slidingWindowEviction() {
        let (limiter, clock) = makeLimiter(window: 60)
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        // 120s later, the first event is long gone and a new op must be
        // admitted on the first check (no second event has happened yet).
        clock.advance(seconds: 120)
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
    }

    // MARK: Per-client isolation

    @Test("client A activity does not consume client B's budget")
    func perClientIsolation() {
        let (limiter, _) = makeLimiter()
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        #expect(limiter.recordAndCheck(clientID: "bravo", tool: "clean") == .allowed)
    }

    @Test("client A exhausted, client B unaffected within the same window")
    func exhaustedClientDoesNotAffectOthers() {
        let (limiter, clock) = makeLimiter()
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") != .allowed)

        clock.advance(seconds: 5)
        #expect(limiter.recordAndCheck(clientID: "bravo", tool: "clean") == .allowed)
    }

    // MARK: Per-tool isolation

    @Test("different tools share budget only per-tool, not globally per-client")
    func perToolIsolation() {
        let (limiter, _) = makeLimiter()
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        // A future `purge` tool must not be starved by a prior `clean` op.
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "purge") == .allowed)
    }

    // MARK: Configurable budgets

    @Test("maxOps higher than 1 allows that many ops per window")
    func configurableMaxOps() {
        let (limiter, clock) = makeLimiter(window: 60, maxOps: 3)
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
        clock.advance(seconds: 1)
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
        clock.advance(seconds: 1)
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
        clock.advance(seconds: 1)
        let over = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        guard case .rejected = over else {
            Issue.record("expected 4th op within window to be rejected")
            return
        }
    }

    @Test("shorter window allows earlier reuse")
    func configurableWindow() {
        let (limiter, clock) = makeLimiter(window: 5, maxOps: 1)
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        clock.advance(seconds: 6)
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
    }

    // MARK: Defaults match PRD §7.4

    @Test("default budget is 1 op per 60s (PRD §7.4)")
    func defaultBudget() {
        let limiter = MCPRateLimiter()
        #expect(limiter.window == 60)
        #expect(limiter.maxOps == 1)
    }

    // MARK: Bookkeeping / diagnostics

    @Test("eventCount reflects active events and prunes expired ones")
    func eventCountAccuracy() {
        let (limiter, clock) = makeLimiter(window: 60, maxOps: 10)
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        #expect(limiter.eventCount(clientID: "alpha", tool: "clean") == 2)

        clock.advance(seconds: 120)
        #expect(limiter.eventCount(clientID: "alpha", tool: "clean") == 0)
    }

    @Test("reset drops all recorded events")
    func resetClearsBudget() {
        let (limiter, _) = makeLimiter()
        _ = limiter.recordAndCheck(clientID: "alpha", tool: "clean")
        limiter.reset()
        #expect(limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed)
    }

    // MARK: Concurrency

    @Test("concurrent attempts admit only up to maxOps")
    func concurrentAdmissionCapped() async {
        let (limiter, _) = makeLimiter(window: 60, maxOps: 1)

        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    limiter.recordAndCheck(clientID: "alpha", tool: "clean") == .allowed
                }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }

        #expect(admitted == 1, "exactly one concurrent attempt must be admitted under maxOps=1")
    }
}
