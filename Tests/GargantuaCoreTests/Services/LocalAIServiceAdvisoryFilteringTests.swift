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

@Suite("LocalAIService advisory filtering")
@MainActor
struct LocalAIServiceAdvisoryFilteringTests {

    @Test("advisory ignores safe-tier items")
    func filtersOutSafe() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeAdvisoryEngine(rationale: "x")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let safeItem = makeResult(id: "safe-1", safety: .safe)
        let rule = makeRule()
        let advisories = try await service.advisory(
            for: [safeItem],
            rules: [safeItem.id: rule]
        )

        #expect(advisories.isEmpty)
        #expect(engine.advisoryCallCount == 0)
    }

    @Test("advisory ignores protected-tier items")
    func filtersOutProtected() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeAdvisoryEngine(rationale: "x")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let protectedItem = makeResult(id: "p-1", safety: .protected_)
        let rule = makeRule()
        let advisories = try await service.advisory(
            for: [protectedItem],
            rules: [protectedItem.id: rule]
        )

        #expect(advisories.isEmpty)
        #expect(engine.advisoryCallCount == 0)
    }

    @Test("advisory returns empty for empty input")
    func emptyInput() async throws {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)

        let advisories = try await service.advisory(for: [], rules: [:])
        #expect(advisories.isEmpty)
    }

    @Test("advisory skips results with no matching rule")
    func skipsMissingRule() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeAdvisoryEngine(rationale: "x")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let r1 = makeResult(id: "has-rule")
        let r2 = makeResult(id: "no-rule")
        let rule = makeRule()
        let advisories = try await service.advisory(
            for: [r1, r2],
            rules: ["has-rule": rule] // r2 intentionally absent
        )

        #expect(advisories.count == 1)
        #expect(advisories[0].resultId == "has-rule")
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
