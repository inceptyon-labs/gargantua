import Foundation
import Testing
@testable import GargantuaCore

private func makeRule(
    id: String = "chrome_cache",
    explanation: String = "Browser cache — review before deletion."
) -> ScanRule {
    ScanRule(
        id: id,
        name: "Chrome Browser Cache",
        paths: ["~/Library/Caches/Google/Chrome"],
        safety: .review,
        confidence: 60,
        explanation: explanation,
        source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
        regenerates: true,
        regenerateCommand: nil,
        category: "browser_cache",
        tags: ["browser", "cache"]
    )
}

private func makeResult(
    id: String = "chrome_cache_001",
    safety: SafetyLevel = .review
) -> ScanResult {
    ScanResult(
        id: id,
        name: "Chrome Browser Cache",
        path: "/Users/test/Library/Caches/Google/Chrome",
        size: 500_000_000,
        safety: safety,
        confidence: 60,
        explanation: "Cache files regenerated automatically.",
        source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
        category: "browser_cache",
        tags: ["browser", "cache"],
        regenerates: true
    )
}

private func makeTempModelFile(contents: String) throws -> (path: String, size: Int64) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("gargantua-test-model-\(UUID().uuidString).bin")
    try contents.data(using: .utf8)!.write(to: url)
    let size = Int64(contents.utf8.count)
    return (url.path, size)
}

@Suite("LocalAIService advisory core behavior")
@MainActor
struct LocalAIServiceAdvisoryCoreBehaviorTests {

    // MARK: - Well-formedness

    @Test("advisory returns well-formed values for review-tier inputs")
    func wellFormedForReviewItems() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeAdvisoryEngine(rationale: "Looks recoverable; double-check before deleting.")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let result = makeResult(id: "item-1")
        let rule = makeRule(id: "chrome_cache")
        let advisories = try await service.advisory(
            for: [result],
            rules: [result.id: rule]
        )

        #expect(advisories.count == 1)
        let advisory = try #require(advisories.first)
        #expect(advisory.resultId == "item-1")
        #expect(advisory.rationale == "Looks recoverable; double-check before deleting.")
        #expect(advisory.suggestedSafety == .review)
        #expect(advisory.source == .ai)
    }

    @Test("advisory processes multiple review items in input order")
    func processesMultipleItems() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeAdvisoryEngine(rationale: "advisory text")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let r1 = makeResult(id: "item-1")
        let r2 = makeResult(id: "item-2")
        let rule = makeRule()
        let advisories = try await service.advisory(
            for: [r1, r2],
            rules: ["item-1": rule, "item-2": rule]
        )

        #expect(advisories.map(\.resultId) == ["item-1", "item-2"])
        #expect(engine.advisoryCallCount == 2)
    }

    // MARK: - Safety invariant

    @Test("advisory does not mutate input ScanResult.safety")
    func doesNotMutateInputSafety() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        // Engine that *tries* to suggest a different safety level. The
        // invariant must hold regardless of what the engine suggests.
        let engine = FakeAdvisoryEngine(
            rationale: "Reclassify as protected",
            overrideSuggestedSafety: .protected_
        )
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let result = makeResult(id: "item-1", safety: .review)
        let rule = makeRule()

        let advisories = try await service.advisory(
            for: [result],
            rules: [result.id: rule]
        )

        // The input struct was not mutated — safety stays at the YAML-derived
        // level regardless of what the engine suggests.
        #expect(result.safety == .review)

        // The advisory surfaces the AI's suggestion as a *separate* field so
        // callers can show "AI thinks X" without the YAML truth ever changing.
        let advisory = try #require(advisories.first)
        #expect(advisory.suggestedSafety == .protected_)
    }

    // MARK: - ScanResultAdvisory value type

    @Test("ScanResultAdvisory equality")
    func advisoryEquality() {
        let a = ScanResultAdvisory(
            resultId: "x",
            rationale: "r",
            suggestedSafety: .review,
            source: .ai
        )
        let b = ScanResultAdvisory(
            resultId: "x",
            rationale: "r",
            suggestedSafety: .review,
            source: .ai
        )
        let c = ScanResultAdvisory(
            resultId: "x",
            rationale: "r",
            suggestedSafety: .safe,
            source: .ai
        )
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Default engine advisory behavior

    @Test("TemplateInferenceEngine default advisory wraps generate() output")
    func templateDefaultAdvisory() async throws {
        let engine = TemplateInferenceEngine()
        let result = makeResult()
        let rule = makeRule()

        let advisory = try await engine.advisory(for: result, rule: rule)

        #expect(advisory.resultId == result.id)
        #expect(advisory.suggestedSafety == result.safety, "default impl carries current safety through")
        #expect(advisory.source == .ai)
        #expect(advisory.rationale.contains("Chrome Browser Cache"),
                "default rationale derives from generate() text")
    }
}

// MARK: - Test doubles

private enum FakeAdvisoryError: Error { case boom }

@MainActor
private final class FakeAdvisoryEngine: AIInferenceEngine {
    let kind: AIEnginePreference
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    private(set) var advisoryCallCount = 0

    private let rationale: String
    private let advisoryError: Error?
    private let failForResultIds: Set<String>
    private let overrideSuggestedSafety: SafetyLevel?

    init(
        rationale: String,
        kind: AIEnginePreference = .mlx,
        advisoryError: Error? = nil,
        failForResultIds: Set<String> = [],
        overrideSuggestedSafety: SafetyLevel? = nil
    ) {
        self.rationale = rationale
        self.kind = kind
        self.advisoryError = advisoryError
        self.failForResultIds = failForResultIds
        self.overrideSuggestedSafety = overrideSuggestedSafety
    }

    func load(modelPath: String, modelSize: Int64) async throws {
        isLoaded = true
        memoryUsage = modelSize
    }

    func unload() {
        isLoaded = false
        memoryUsage = 0
    }

    func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        rationale
    }

    func advisory(for result: ScanResult, rule: ScanRule) async throws -> ScanResultAdvisory {
        advisoryCallCount += 1
        if let err = advisoryError {
            throw err
        }
        if failForResultIds.contains(result.id) {
            throw FakeAdvisoryError.boom
        }
        return ScanResultAdvisory(
            resultId: result.id,
            rationale: rationale,
            suggestedSafety: overrideSuggestedSafety ?? result.safety,
            source: .ai
        )
    }
}
