import Foundation
import Testing
@testable import GargantuaCore

@Suite("AIExplanationController")
@MainActor
struct AIExplanationControllerTests {

    // MARK: - Fixtures

    private func makeResult(id: String = "r1", name: String = "Chrome Cache") -> ScanResult {
        ScanResult(
            id: id,
            name: name,
            path: "/tmp/cache",
            size: 1024,
            safety: .safe,
            confidence: 98,
            explanation: "Regenerated on launch.",
            source: SourceAttribution(name: "Chrome", bundleID: "com.google.Chrome"),
            category: "browser_cache",
            tags: ["browser"],
            regenerates: true,
            regenerateCommand: "open -a Chrome"
        )
    }

    // MARK: - Rule derivation

    @Test("derivedRule carries every field the prompt builder reads")
    func derivedRuleMirrorsResult() {
        let result = makeResult()
        let rule = AIExplanationController.derivedRule(from: result)

        #expect(rule.id == result.category)
        #expect(rule.name == result.name)
        #expect(rule.paths == [result.path])
        #expect(rule.safety == result.safety)
        #expect(rule.confidence == result.confidence)
        #expect(rule.explanation == result.explanation)
        #expect(rule.source.name == result.source.name)
        #expect(rule.regenerates == result.regenerates)
        #expect(rule.regenerateCommand == result.regenerateCommand)
        #expect(rule.category == result.category)
        #expect(rule.tags == result.tags)
    }

    // MARK: - State machine

    @Test("explain transitions through loading then loaded on success")
    func loadingThenLoaded() async {
        let service = StubAIService(result: .success(AIExplanation(text: "hi", source: .ai)))
        let controller = AIExplanationController(service: service)

        controller.explain(makeResult())

        // Immediately after the call the controller is in .loading.
        guard case .loading = controller.presentation else {
            Issue.record("Expected .loading, got \(String(describing: controller.presentation))")
            return
        }

        await service.complete()
        try? await Task.sleep(for: .milliseconds(20))

        guard case .loaded(_, let explanation) = controller.presentation else {
            Issue.record("Expected .loaded, got \(String(describing: controller.presentation))")
            return
        }
        #expect(explanation.text == "hi")
        #expect(explanation.source == .ai)
    }

    @Test("explain transitions to failed on thrown error")
    func failsOnError() async {
        let service = StubAIService(result: .failure(StubError.boom))
        let controller = AIExplanationController(service: service)

        controller.explain(makeResult())
        await service.complete()
        try? await Task.sleep(for: .milliseconds(20))

        guard case .failed(_, let message) = controller.presentation else {
            Issue.record("Expected .failed, got \(String(describing: controller.presentation))")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("dismiss clears state and cancels any in-flight request")
    func dismissCancels() async {
        let service = StubAIService(result: .success(AIExplanation(text: "late", source: .ai)))
        let controller = AIExplanationController(service: service)

        controller.explain(makeResult())
        controller.dismiss()

        #expect(controller.presentation == nil)

        // Even if the service later produces a result, nothing should land
        // because the task was cancelled.
        await service.complete()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.presentation == nil)
    }

    @Test("a newer explain request supersedes an older one")
    func newerRequestWins() async {
        let service = StubAIService(result: .success(AIExplanation(text: "first", source: .ai)))
        let controller = AIExplanationController(service: service)

        controller.explain(makeResult(id: "first"))
        // Second request arrives before the first finishes.
        controller.explain(makeResult(id: "second"))
        await service.complete()
        try? await Task.sleep(for: .milliseconds(20))

        // Only the latest result's presentation should be visible.
        #expect(controller.presentation?.result.id == "second")
    }

    @Test("isBusy tracks loading state")
    func isBusyTracksLoading() async {
        let service = StubAIService(result: .success(AIExplanation(text: "x", source: .ai)))
        let controller = AIExplanationController(service: service)

        #expect(controller.isBusy == false)
        controller.explain(makeResult())
        #expect(controller.isBusy == true)

        await service.complete()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.isBusy == false)
    }
}

// MARK: - Test doubles

private enum StubError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "stub failure" }
}

@MainActor
private final class StubAIService: AIServiceProtocol {
    var lifecycleState: AIModelLifecycleState = .unloaded
    var isModelAvailable: Bool = true
    var modelMemoryUsage: Int64 = 0

    private let result: Result<AIExplanation, Error>
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: Result<AIExplanation, Error>) {
        self.result = result
    }

    /// Release a suspended `explain` call so its result lands. Waits until
    /// `explain` has actually suspended on the gate so tests can reliably
    /// observe `.loading` first.
    func complete() async {
        while gate == nil {
            await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
                waiters.append(cc)
            }
        }
        let g = gate
        gate = nil
        g?.resume()
    }

    func explain(result: ScanResult, rule: ScanRule) async throws -> AIExplanation {
        await withCheckedContinuation { cc in
            gate = cc
            let pending = waiters
            waiters = []
            for w in pending { w.resume() }
        }
        switch self.result {
        case .success(let explanation): return explanation
        case .failure(let error): throw error
        }
    }

    func unloadModel() {}
}
