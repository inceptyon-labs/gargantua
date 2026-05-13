import Foundation
import Testing
@testable import GargantuaCore

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

@Suite("LocalAIService inference engine boundary")
@MainActor
struct LocalAIServiceInferenceEngineTests {

    // MARK: - Template fallback

    @Test("No model + Template engine produces .template output without loading model")
    func templateRunsWithoutModel() async throws {
        let manager = makeNeverDownloadedManager()
        let service = LocalAIService(downloadManager: manager)

        let rule = makeRule(explanation: "Browser cache — safe to remove.")
        let result = makeResult()

        let explanation = try await service.explain(result: result, rule: rule)

        #expect(explanation.source == .template)
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

    // MARK: - Engine routing

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

    // MARK: - MLXInferenceEngine validation

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

    // MARK: - Idle timer and memory guard

    @Test("Idle timer does not unload during in-flight inference")
    func idleTimerSuspendedDuringInference() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

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

    // MARK: - TemplateInferenceEngine direct + selection

    @Test("TemplateInferenceEngine produces structured text")
    func templateEngineProducesText() async throws {
        let engine = TemplateInferenceEngine()
        let text = try await engine.generate(for: makeResult(), rule: makeRule())
        #expect(text.contains("Chrome Browser Cache"))
        #expect(text.contains("browser cache"))
        #expect(text.contains("Safety:"))
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
    private(set) var unloadCallsDuringGenerate = 0

    private let output: String
    private let loadError: Error?
    private let generateError: Error?
    private let generateDelay: Duration?
    private let reportedMemoryUsage: Int64?
    private var inFlight: Int = 0

    init(
        output: String,
        kind: AIEnginePreference = .mlx,
        loadError: Error? = nil,
        generateError: Error? = nil,
        generateDelay: Duration? = nil,
        reportedMemoryUsage: Int64? = nil
    ) {
        self.output = output
        self.kind = kind
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
