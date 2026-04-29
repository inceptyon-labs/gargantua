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

    /// Returns a `ModelDownloadManager` whose manifest points at a unique,
    /// never-staged directory. Prevents collisions with a real `defaultModel`
    /// directory a developer may have downloaded on this machine, which would
    /// otherwise flip these tests from `.notDownloaded` to `.downloaded`.
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

    // MARK: - Fallback to YAML

    @Test("No model + Template engine produces .template output without loading model")
    func templateRunsWithoutModel() async throws {
        let manager = makeNeverDownloadedManager()
        // Default engine is `TemplateInferenceEngine` which doesn't need
        // model weights; the service should run it directly.
        let service = LocalAIService(downloadManager: manager)

        let rule = makeRule(explanation: "Browser cache — safe to remove.")
        let result = makeResult()

        let explanation = try await service.explain(result: result, rule: rule)

        #expect(explanation.source == .template)
        // Structured template output stitches rule.explanation in.
        #expect(explanation.text.contains("Browser cache — safe to remove."))
        #expect(service.lifecycleState == .unloaded)
    }

    @Test("No model + Template engine error falls back to .rule + raw YAML")
    func templateEngineErrorFallsBackToRule() async throws {
        let manager = makeNeverDownloadedManager()
        let engine = FakeInferenceEngine(
            output: "unused",
            kind: .template,
            generateError: FakeEngineError.boom
        )
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let rule = makeRule(explanation: "Raw YAML fallback text.")
        let explanation = try await service.explain(result: makeResult(), rule: rule)

        #expect(explanation.source == .rule)
        #expect(explanation.text == "Raw YAML fallback text.")
    }

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

    @Test("Engine load failure falls back to YAML rule explanation")
    func engineLoadFailureFallsBack() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = FakeInferenceEngine(output: "unused", loadError: FakeEngineError.boom)
        let service = LocalAIService(downloadManager: manager, engine: engine)
        let rule = makeRule(explanation: "Load failed fallback.")

        let explanation = try await service.explain(result: makeResult(), rule: rule)

        #expect(explanation.source == .rule)
        #expect(explanation.text == "Load failed fallback.")
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

    @Test("Post-load memory guard falls back to YAML rule explanation")
    func residentMemoryGuardFallsBack() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        // Engine reports resident memory far above the 3 GB limit, despite
        // a small on-disk file (simulating decompressed weights).
        let bloated = LocalAIService.maxModelMemory + 1_000_000
        let engine = FakeInferenceEngine(output: "unused", reportedMemoryUsage: bloated)
        let service = LocalAIService(downloadManager: manager, engine: engine)
        let rule = makeRule(explanation: "Resident guard fallback.")

        let explanation = try await service.explain(result: makeResult(), rule: rule)

        #expect(explanation.source == .rule)
        #expect(explanation.text == "Resident guard fallback.")
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

    @Test("scan filter asks injected engine even when no model is downloaded")
    func scanFilterUsesInjectedEngineWithoutModel() async throws {
        let manager = makeNeverDownloadedManager()
        let filter = ScanFilterSet(categories: ["dev_artifacts"], safetyLevels: [.review])
        let engine = FakeInferenceEngine(output: "unused", scanFilter: filter)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let resolved = try await service.scanFilter(for: "show me everything related to Xcode")

        #expect(resolved == filter)
        #expect(engine.scanFilterCallCount == 1)
        #expect(engine.loadCallCount == 0)
    }

    @Test("scan filter returns nil on engine failure")
    func scanFilterFailureFallsBackToNil() async throws {
        let manager = makeNeverDownloadedManager()
        let engine = FakeInferenceEngine(output: "unused", scanFilterError: FakeEngineError.boom)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let resolved = try await service.scanFilter(for: "unparseable")

        #expect(resolved == nil)
    }

    @Test("TemplateInferenceEngine maps Xcode query to scan filter")
    func templateEngineMapsXcodeQueryToFilter() async throws {
        let engine = TemplateInferenceEngine()

        let filter = try #require(try await engine.scanFilter(for: "Show me everything related to Xcode"))

        #expect(filter.bundleIDs.contains("com.apple.dt.Xcode"))
        #expect(filter.categories.contains("dev_artifacts"))
        #expect(filter.pathGlobs.contains(where: { $0.localizedCaseInsensitiveContains("Xcode") }))
    }

    @Test("Template engine produces .template-sourced output, not .ai")
    func templateSelectionWorksWithModelDirectory() async throws {
        let model = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: model.url) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: model.url.path, size: model.size))
        let service = LocalAIService(downloadManager: manager, engine: TemplateInferenceEngine())

        let explanation = try await service.explain(result: makeResult(), rule: makeRule())

        #expect(explanation.source == .template)
        #expect(explanation.text.contains("Chrome Browser Cache"))
        // Template engine doesn't trigger model load anymore — lifecycle stays
        // unloaded even when a model file is present on disk.
        #expect(service.lifecycleState == .unloaded)
    }

    @Test("First MLX inference flips warmup flag; Template inference does not")
    func firstMLXInferenceMarksWarmup() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let templateEngine = FakeInferenceEngine(output: "out", kind: .template)
        let service = LocalAIService(downloadManager: manager, engine: templateEngine)

        let templateExplanation = try await service.explain(result: makeResult(), rule: makeRule())
        #expect(templateExplanation.source == .template)
        #expect(service.hasCompletedFirstMLXInference == false)

        let mlxEngine = FakeInferenceEngine(output: "out", kind: .mlx)
        service.configureEngine(mlxEngine)
        #expect(service.hasCompletedFirstMLXInference == false)

        let mlxExplanation = try await service.explain(result: makeResult(), rule: makeRule())
        #expect(mlxExplanation.source == .ai)
        #expect(service.hasCompletedFirstMLXInference == true)
    }

    // MARK: - Test helpers

    private func makeTempModelFile(contents: String) throws -> (path: String, size: Int64) {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("gargantua-test-model-\(UUID().uuidString).bin")
        try contents.data(using: .utf8)!.write(to: url)
        let size = Int64(contents.utf8.count)
        return (url.path, size)
    }

    private func makeTempModelDirectory() throws -> (url: URL, size: Int64) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let files: [(String, String)] = [
            ("config.json", "{}"),
            ("tokenizer_config.json", "{}"),
            ("model.safetensors", "weights"),
        ]
        var total: Int64 = 0
        for (name, contents) in files {
            let data = try #require(contents.data(using: .utf8))
            try data.write(to: dir.appendingPathComponent(name))
            total += Int64(data.count)
        }
        return (dir, total)
    }
}

// MARK: - Test doubles

private enum FakeEngineError: Error { case boom }

@MainActor
private final class FakeInferenceEngine: AIInferenceEngine {
    let kind: AIEnginePreference
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    private(set) var loadCallCount = 0
    private(set) var unloadCallCount = 0
    private(set) var generateCallCount = 0
    private(set) var scanFilterCallCount = 0
    private(set) var unloadCallsDuringGenerate = 0

    private let output: String
    private let loadError: Error?
    private let generateError: Error?
    private let scanFilter: ScanFilterSet?
    private let scanFilterError: Error?
    private let generateDelay: Duration?
    private let reportedMemoryUsage: Int64?
    private var inFlight: Int = 0

    init(
        output: String,
        kind: AIEnginePreference = .mlx,
        loadError: Error? = nil,
        generateError: Error? = nil,
        scanFilter: ScanFilterSet? = nil,
        scanFilterError: Error? = nil,
        generateDelay: Duration? = nil,
        reportedMemoryUsage: Int64? = nil
    ) {
        self.output = output
        self.kind = kind
        self.loadError = loadError
        self.generateError = generateError
        self.scanFilter = scanFilter
        self.scanFilterError = scanFilterError
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

    func scanFilter(for query: String) async throws -> ScanFilterSet? {
        scanFilterCallCount += 1
        if let scanFilterError {
            throw scanFilterError
        }
        return scanFilter
    }
}
