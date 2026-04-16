import Foundation
import Testing
@testable import GargantuaCore

@Suite("LocalAIService")
@MainActor
struct LocalAIServiceTests {

    // MARK: - Fixtures

    private func makeRule(
        explanation: String = "Cache files regenerated automatically."
    ) -> ScanRule {
        ScanRule(
            id: "chrome_cache",
            name: "Chrome Browser Cache",
            paths: ["~/Library/Caches/Google/Chrome"],
            safety: .safe,
            confidence: 98,
            explanation: explanation,
            source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
            regenerates: true,
            regenerateCommand: nil,
            category: "browser_cache",
            tags: ["browser", "cache"]
        )
    }

    private func makeResult() -> ScanResult {
        ScanResult(
            id: "chrome_cache_001",
            name: "Chrome Browser Cache",
            path: "/Users/test/Library/Caches/Google/Chrome",
            size: 500_000_000,
            safety: .safe,
            confidence: 98,
            explanation: "Cache files regenerated automatically.",
            source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
            category: "browser_cache",
            tags: ["browser", "cache"],
            regenerates: true
        )
    }

    // MARK: - Fallback to YAML

    @Test("Returns YAML rule explanation when no model downloaded")
    func fallbackWhenNoModel() async throws {
        let manager = ModelDownloadManager()
        // Default state is .notDownloaded — no model on disk
        let service = LocalAIService(downloadManager: manager)

        let rule = makeRule(explanation: "Browser cache — safe to remove.")
        let result = makeResult()

        let explanation = try await service.explain(result: result, rule: rule)

        #expect(explanation.source == .rule)
        #expect(explanation.text == "Browser cache — safe to remove.")
    }

    @Test("isModelAvailable is false when no model downloaded")
    func modelNotAvailable() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)

        #expect(!service.isModelAvailable)
    }

    @Test("Initial lifecycle state is unloaded")
    func initialStateUnloaded() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)

        #expect(service.lifecycleState == .unloaded)
        #expect(service.modelMemoryUsage == 0)
    }

    // MARK: - Unload

    @Test("unloadModel resets state to unloaded")
    func unloadResetsState() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)

        // Even from initial state, unload should be safe
        service.unloadModel()

        #expect(service.lifecycleState == .unloaded)
        #expect(service.modelMemoryUsage == 0)
    }

    // MARK: - Protocol Conformance

    @Test("Conforms to AIServiceProtocol")
    func protocolConformance() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)
        let _: any AIServiceProtocol = service
        // Compiles = conforms
    }

    // MARK: - AIExplanation

    @Test("AIExplanation preserves text and source")
    func explanationInit() {
        let aiExplanation = AIExplanation(text: "Generated", source: .ai)
        #expect(aiExplanation.text == "Generated")
        #expect(aiExplanation.source == .ai)

        let ruleExplanation = AIExplanation(text: "From YAML", source: .rule)
        #expect(ruleExplanation.text == "From YAML")
        #expect(ruleExplanation.source == .rule)
    }

    // MARK: - ExplanationSource Equatable

    @Test("ExplanationSource equality")
    func sourceEquality() {
        #expect(ExplanationSource.ai == ExplanationSource.ai)
        #expect(ExplanationSource.rule == ExplanationSource.rule)
        #expect(ExplanationSource.ai != ExplanationSource.rule)
    }

    // MARK: - AIModelLifecycleState

    @Test("AIModelLifecycleState equality")
    func lifecycleStateEquality() {
        #expect(AIModelLifecycleState.unloaded == AIModelLifecycleState.unloaded)
        #expect(AIModelLifecycleState.loading == AIModelLifecycleState.loading)
        #expect(AIModelLifecycleState.ready == AIModelLifecycleState.ready)
        #expect(AIModelLifecycleState.unloaded != AIModelLifecycleState.ready)
    }

    // MARK: - AIServiceError

    @Test("AIServiceError modelTooLarge has descriptive message")
    func errorDescription() {
        let error = AIServiceError.modelTooLarge(size: 4_000_000_000, limit: 3_000_000_000)
        let description = error.errorDescription ?? ""
        #expect(description.contains("exceeds limit"))
    }

    @Test("AIServiceError loadFailed wraps underlying error")
    func loadFailedError() {
        let underlying = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "disk read failed"])
        let error = AIServiceError.loadFailed(underlying: underlying)
        let description = error.errorDescription ?? ""
        #expect(description.contains("disk read failed"))
    }

    // MARK: - Max Memory Constant

    @Test("Max model memory is 3 GB")
    func maxMemoryConstant() {
        #expect(LocalAIService.maxModelMemory == 3_000_000_000)
    }

    // MARK: - Idle Timeout Configuration

    @Test("Custom idle timeout is stored")
    func customIdleTimeout() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager, idleTimeout: 120)
        #expect(service.idleTimeout == 120)
    }

    @Test("Default idle timeout is 60 seconds")
    func defaultIdleTimeout() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)
        #expect(service.idleTimeout == 60)
    }
}
