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

    // MARK: - Inference Engine Boundary

    @Test("Injected engine is used when model is available")
    func injectedEngineProducesOutput() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeInferenceEngine(output: "ENGINE_OUTPUT")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let explanation = try await service.explain(result: makeResult(), rule: makeRule())

        #expect(explanation.source == .ai)
        #expect(explanation.text == "ENGINE_OUTPUT")
        #expect(engine.generateCallCount == 1)
        #expect(engine.loadCallCount == 1)
    }

    @Test("Engine generate failure falls back to YAML rule explanation")
    func engineGenerateFailureFallsBack() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeInferenceEngine(output: "unused", generateError: FakeEngineError.boom)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let rule = makeRule(explanation: "YAML fallback text.")
        let explanation = try await service.explain(result: makeResult(), rule: rule)

        #expect(explanation.source == .rule)
        #expect(explanation.text == "YAML fallback text.")
        #expect(service.lifecycleState == .ready, "engine load succeeded even though generate failed")
    }

    @Test("Engine load failure is wrapped in AIServiceError.loadFailed")
    func engineLoadFailureWrapped() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeInferenceEngine(output: "unused", loadError: FakeEngineError.boom)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        await #expect(throws: AIServiceError.self) {
            _ = try await service.explain(result: self.makeResult(), rule: self.makeRule())
        }
        #expect(service.lifecycleState == .unloaded)
        #expect(service.modelMemoryUsage == 0)
    }

    @Test("unloadModel forwards to engine")
    func unloadForwardsToEngine() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeInferenceEngine(output: "x")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        _ = try await service.explain(result: makeResult(), rule: makeRule())
        #expect(engine.isLoaded == true)

        service.unloadModel()

        #expect(engine.unloadCallCount >= 1)
        #expect(engine.isLoaded == false)
        #expect(service.modelMemoryUsage == 0)
        #expect(service.lifecycleState == .unloaded)
    }

    @Test("MLXInferenceEngine.load rejects non-existent path")
    func mlxEngineLoadRejectsMissingPath() async {
        let engine = MLXInferenceEngine()
        await #expect(throws: MLXInferenceError.self) {
            try await engine.load(
                modelPath: "/tmp/gargantua-no-such-model-\(UUID().uuidString)",
                modelSize: 1
            )
        }
    }

    @Test("MLXInferenceEngine.generate before load throws notLoaded")
    func mlxEngineGenerateBeforeLoadThrows() async {
        let engine = MLXInferenceEngine()
        await #expect(throws: MLXInferenceError.self) {
            _ = try await engine.generate(for: makeResult(), rule: makeRule())
        }
    }

    @Test("Idle timer does not unload during in-flight inference")
    func idleTimerSuspendedDuringInference() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        // Use a very short idle timeout and a slow engine whose generate
        // takes longer than the timeout. The timer must not unload mid-call.
        let engine = FakeInferenceEngine(output: "SLOW", generateDelay: .milliseconds(200))
        let service = LocalAIService(downloadManager: manager, engine: engine, idleTimeout: 0.05)

        let explanation = try await service.explain(result: makeResult(), rule: makeRule())

        #expect(explanation.source == .ai)
        #expect(explanation.text == "SLOW")
        #expect(engine.unloadCallsDuringGenerate == 0, "engine was unloaded while generate was in flight")
    }

    @Test("Post-load memory guard rejects models over RAM limit")
    func residentMemoryGuard() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        // Engine reports resident memory far above the 3 GB limit, despite
        // a small on-disk file (simulating decompressed weights).
        let bloated = LocalAIService.maxModelMemory + 1_000_000
        let engine = FakeInferenceEngine(output: "unused", reportedMemoryUsage: bloated)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        await #expect(throws: AIServiceError.self) {
            _ = try await service.explain(result: self.makeResult(), rule: self.makeRule())
        }
        #expect(service.lifecycleState == .unloaded)
        #expect(service.modelMemoryUsage == 0)
        #expect(engine.unloadCallCount >= 1)
    }

    @Test("TemplateInferenceEngine produces structured text")
    func templateEngineProducesText() async throws {
        let engine = TemplateInferenceEngine()
        let text = try await engine.generate(for: makeResult(), rule: makeRule())
        #expect(text.contains("Chrome Browser Cache"))
        #expect(text.contains("browser cache"))
        #expect(text.contains("Safety:"))
    }

    // MARK: - Test helpers

    private func makeTempModelFile(contents: String) throws -> (path: String, size: Int64) {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("gargantua-test-model-\(UUID().uuidString).bin")
        try contents.data(using: .utf8)!.write(to: url)
        let size = Int64(contents.utf8.count)
        return (url.path, size)
    }
}

// MARK: - Test doubles

private enum FakeEngineError: Error { case boom }

@MainActor
private final class FakeInferenceEngine: AIInferenceEngine {
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    private(set) var loadCallCount = 0
    private(set) var unloadCallCount = 0
    private(set) var generateCallCount = 0
    private(set) var unloadCallsDuringGenerate = 0

    private let output: String
    private let loadError: Error?
    private let generateError: Error?
    private let generateDelay: Duration?
    private let reportedMemoryUsage: Int64?
    private var inFlight: Int = 0

    init(
        output: String,
        loadError: Error? = nil,
        generateError: Error? = nil,
        generateDelay: Duration? = nil,
        reportedMemoryUsage: Int64? = nil
    ) {
        self.output = output
        self.loadError = loadError
        self.generateError = generateError
        self.generateDelay = generateDelay
        self.reportedMemoryUsage = reportedMemoryUsage
    }

    func load(modelPath: String, modelSize: Int64) async throws {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        isLoaded = true
        memoryUsage = reportedMemoryUsage ?? modelSize
    }

    func unload() {
        unloadCallCount += 1
        if inFlight > 0 {
            unloadCallsDuringGenerate += 1
        }
        isLoaded = false
        memoryUsage = 0
    }

    func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        generateCallCount += 1
        inFlight += 1
        defer { inFlight -= 1 }
        if let generateDelay {
            try? await Task.sleep(for: generateDelay)
        }
        if let generateError {
            throw generateError
        }
        return output
    }
}
