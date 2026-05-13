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

@MainActor
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

private func makeTempModelFile(contents: String) throws -> (path: String, size: Int64) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("gargantua-test-model-\(UUID().uuidString).bin")
    try contents.data(using: .utf8)!.write(to: url)
    let size = Int64(contents.utf8.count)
    return (url.path, size)
}

@Suite("LocalAIService advisory fallback")
@MainActor
struct LocalAIServiceAdvisoryFallbackTests {

    @Test("advisory falls back to YAML rule text when engine throws")
    func fallsBackOnEngineFailure() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeAdvisoryEngine(
            rationale: "unused",
            advisoryError: FakeAdvisoryError.boom
        )
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let result = makeResult(id: "item-1")
        let rule = makeRule(explanation: "YAML fallback rationale.")
        let advisories = try await service.advisory(
            for: [result],
            rules: [result.id: rule]
        )

        let advisory = try #require(advisories.first)
        #expect(advisory.source == .rule)
        #expect(advisory.rationale == "YAML fallback rationale.")
        #expect(advisory.suggestedSafety == .review, "fallback carries through current safety")
    }

    @Test("advisory uses Template engine when no model is downloaded")
    func templateAdvisoryWithoutModel() async throws {
        let manager = makeNeverDownloadedManager()
        // Default engine is `TemplateInferenceEngine`, which doesn't need a
        // model — the service runs it directly and stamps `.template`.
        let service = LocalAIService(downloadManager: manager)

        let result = makeResult()
        let rule = makeRule(explanation: "YAML rule text.")
        let advisories = try await service.advisory(
            for: [result],
            rules: [result.id: rule]
        )

        let advisory = try #require(advisories.first)
        #expect(advisory.source == .template)
        // Template stitches rule.explanation in, so the rationale contains it
        // even though it's structured prose, not raw YAML.
        #expect(advisory.rationale.contains("YAML rule text."))
    }

    @Test("advisory falls back per-item — some AI, some YAML when engine partially fails")
    func perItemFallback() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        // Engine throws only for item-2.
        let engine = FakeAdvisoryEngine(
            rationale: "ai text",
            failForResultIds: ["item-2"]
        )
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let r1 = makeResult(id: "item-1")
        let r2 = makeResult(id: "item-2")
        let rule1 = makeRule(explanation: "rule 1 text")
        let rule2 = makeRule(explanation: "rule 2 text")

        let advisories = try await service.advisory(
            for: [r1, r2],
            rules: ["item-1": rule1, "item-2": rule2]
        )

        #expect(advisories.count == 2)
        #expect(advisories[0].source == .ai)
        #expect(advisories[0].rationale == "ai text")
        #expect(advisories[1].source == .rule)
        #expect(advisories[1].rationale == "rule 2 text")
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
