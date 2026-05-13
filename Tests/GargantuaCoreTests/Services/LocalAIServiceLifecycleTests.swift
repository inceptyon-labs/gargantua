import Foundation
import Testing
@testable import GargantuaCore

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

@Suite("LocalAIService lifecycle and value types")
@MainActor
struct LocalAIServiceLifecycleTests {

    // MARK: - Lifecycle / availability

    @Test("isModelAvailable is false when no model downloaded")
    func modelNotAvailable() {
        let manager = makeNeverDownloadedManager()
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

    @Test("unloadModel resets state to unloaded")
    func unloadResetsState() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)

        service.unloadModel()

        #expect(service.lifecycleState == .unloaded)
        #expect(service.modelMemoryUsage == 0)
    }

    @Test("Conforms to AIServiceProtocol")
    func protocolConformance() {
        let manager = ModelDownloadManager()
        let service = LocalAIService(downloadManager: manager)
        let _: any AIServiceProtocol = service
    }

    // MARK: - Configuration

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

    @Test("Max model memory is 3 GB")
    func maxMemoryConstant() {
        #expect(LocalAIService.maxModelMemory == 3_000_000_000)
    }

    // MARK: - AIExplanation value type

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
        let underlying = NSError(
            domain: "test",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "disk read failed"]
        )
        let error = AIServiceError.loadFailed(underlying: underlying)
        let description = error.errorDescription ?? ""
        #expect(description.contains("disk read failed"))
    }
}
