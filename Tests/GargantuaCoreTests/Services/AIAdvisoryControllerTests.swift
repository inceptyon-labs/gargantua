import Foundation
import Testing
@testable import GargantuaCore

@Suite("AIAdvisoryController")
@MainActor
struct AIAdvisoryControllerTests {

    // MARK: - Fixtures

    private func makeResult(
        id: String = "result-1",
        safety: SafetyLevel = .review,
        explanation: String = "Review-tier YAML explanation."
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Sample Cache",
            path: "/Users/test/Library/Caches/Sample",
            size: 100_000,
            safety: safety,
            confidence: 55,
            explanation: explanation,
            source: SourceAttribution(name: "Sample", bundleID: nil),
            category: "cache",
            tags: ["cache"],
            regenerates: true
        )
    }

    private func makeNeverDownloadedManager() -> ModelDownloadManager {
        let info = ModelInfo(
            id: "test-never-\(UUID().uuidString)",
            name: "Unstaged test model",
            files: [
                ModelFile(
                    name: "placeholder",
                    url: URL(string: "https://example.invalid/x")!,
                    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
                    size: 1
                ),
            ]
        )
        return ModelDownloadManager(modelInfo: info)
    }

    // MARK: - Initial state

    @Test("Initial presentation is nil and isBusy is false")
    func initialState() {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        #expect(controller.presentation == nil)
        #expect(controller.isBusy == false)
    }

    // MARK: - Request: YAML fallback path (no model staged)

    @Test("request yields loaded state with .template advisories when no model")
    func requestProducesTemplateOutputWithoutModel() async throws {
        let manager = makeNeverDownloadedManager()
        // Default engine is `TemplateInferenceEngine` — runs without a model
        // and stamps `.template` on every advisory.
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        let results = [makeResult(id: "r1"), makeResult(id: "r2")]
        controller.request(for: results)

        // Drain the Task — give the continuation a few ticks to run.
        try await Self.waitForPresentation(controller, timeout: .seconds(30)) {
            if case .loaded = $0 { return true }
            return false
        }

        guard case .loaded(let advisories) = controller.presentation else {
            Issue.record("presentation did not reach .loaded: \(String(describing: controller.presentation))")
            return
        }
        #expect(advisories.count == 2)
        #expect(advisories.allSatisfy { $0.source == .template })
    }

    @Test("request filters non-review items")
    func requestFiltersNonReviewItems() async throws {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        let results = [
            makeResult(id: "safe-1", safety: .safe),
            makeResult(id: "review-1", safety: .review),
            makeResult(id: "protected-1", safety: .protected_),
        ]
        controller.request(for: results)

        try await Self.waitForPresentation(controller, timeout: .seconds(30)) {
            if case .loaded = $0 { return true }
            return false
        }

        guard case .loaded(let advisories) = controller.presentation else {
            Issue.record("did not reach .loaded")
            return
        }
        #expect(advisories.count == 1)
        #expect(advisories.first?.resultId == "review-1")
    }

    // MARK: - Safety invariant (controller layer)

    @Test("request never mutates caller's ScanResult.safety")
    func doesNotMutateCallerSafety() async throws {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        let results = [makeResult(id: "r1", safety: .review)]
        let snapshot = results[0].safety
        controller.request(for: results)

        try await Self.waitForPresentation(controller, timeout: .seconds(30)) {
            if case .loaded = $0 { return true }
            return false
        }

        // Caller's array is unchanged; even the local `var` binding keeps its
        // original safety because Swift structs are value types.
        #expect(results[0].safety == snapshot)
        #expect(results[0].safety == .review)
    }

    // MARK: - Dismiss + lifecycle

    @Test("dismiss clears presentation and cancels active request")
    func dismissClearsPresentation() async throws {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        controller.request(for: [makeResult()])
        controller.dismiss()
        #expect(controller.presentation == nil)
        #expect(controller.isBusy == false)
    }

    @Test("calling request twice keeps the latest call's result")
    func latestRequestWins() async throws {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        controller.request(for: [makeResult(id: "first")])
        controller.request(for: [makeResult(id: "second")])

        try await Self.waitForPresentation(controller, timeout: .seconds(30)) {
            if case .loaded = $0 { return true }
            return false
        }

        guard case .loaded(let advisories) = controller.presentation else {
            Issue.record("did not reach .loaded")
            return
        }
        // One review item from the latest request, not both.
        #expect(advisories.map(\.resultId) == ["second"])
    }

    // MARK: - Result lookup for UI

    @Test("result(for:) returns the ScanResult behind an advisory id")
    func resultLookup() async throws {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)
        let controller = AIAdvisoryController(service: service)

        let target = makeResult(id: "review-1")
        controller.request(for: [target, makeResult(id: "safe-1", safety: .safe)])

        try await Self.waitForPresentation(controller, timeout: .seconds(30)) {
            if case .loaded = $0 { return true }
            return false
        }

        // Both results (including the safe one that was filtered out of the
        // advisory) should still be reachable by id — the sheet needs to
        // look up by resultId from the loaded advisories regardless of tier.
        #expect(controller.result(for: "review-1")?.name == target.name)
        #expect(controller.result(for: "safe-1") != nil)
        #expect(controller.result(for: "absent") == nil)
    }

    // MARK: - Derived rule helper

    @Test("derivedRules maps every result id to a rule carrying the result's fields")
    func derivedRulesContainExpectedFields() throws {
        let result = makeResult(id: "r1", explanation: "Original explanation.")
        let rules = AIAdvisoryController.derivedRules(for: [result])

        let rule = try #require(rules["r1"])
        #expect(rule.explanation == "Original explanation.")
        #expect(rule.safety == .review)
        #expect(rule.name == result.name)
        #expect(rule.category == result.category)
        #expect(rule.paths == [result.path])
    }

    @Test("derivedRules keyed by result id even for duplicate categories")
    func derivedRulesKeyedByResultId() {
        let r1 = makeResult(id: "r1")
        let r2 = makeResult(id: "r2")
        let rules = AIAdvisoryController.derivedRules(for: [r1, r2])

        #expect(rules.count == 2)
        #expect(rules["r1"] != nil)
        #expect(rules["r2"] != nil)
    }

    // MARK: - Presentation equality

    @Test("AIAdvisoryPresentation equality and stable id")
    func presentationEquality() {
        let a = AIAdvisoryPresentation.loading
        let b = AIAdvisoryPresentation.loading
        let loaded = AIAdvisoryPresentation.loaded([])
        #expect(a == b)
        #expect(a != loaded)
        #expect(a.id == "advisory")
        #expect(loaded.id == "advisory")
    }

    // MARK: - Helpers

    /// Polls the controller's presentation until `predicate` is true or the
    /// timeout elapses. Test-only — production code should observe `@Published`
    /// directly via SwiftUI.
    private static func waitForPresentation(
        _ controller: AIAdvisoryController,
        timeout: Duration,
        predicate: @MainActor (AIAdvisoryPresentation?) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(controller.presentation) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for presentation predicate")
    }
}
