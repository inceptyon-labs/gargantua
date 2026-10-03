import Foundation
import Testing
@testable import GargantuaCore

@Suite("LocalAIService engine swap during load")
@MainActor
struct LocalAIServiceEngineSwapTests {
    @Test("Swapping engines mid-load doesn't mark the new, unloaded engine ready")
    func swapDuringLoadStaysUnloaded() async throws {
        let modelFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-swap-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: modelFile)
        defer { try? FileManager.default.removeItem(at: modelFile) }
        let manager = ModelDownloadManager(modelInfo: ModelInfo(id: "swap-\(UUID().uuidString)", name: "T", files: [
            ModelFile(name: "w", url: URL(string: "https://example.invalid/w")!, sha256: "00", size: 3),
        ]))
        manager._setStateForTesting(.downloaded(path: modelFile.path, size: 3))
        let loading = GatedLoadEngine()
        let replacement = GatedLoadEngine()
        let service = LocalAIService(downloadManager: manager, engine: loading)

        let load = Task { try await service.loadModel() }
        while !loading.isWaiting { await Task.yield() }
        service.configureEngine(replacement)
        loading.open()
        try await load.value

        #expect(service.lifecycleState == .unloaded)
        #expect(!loading.isLoaded)
        #expect(!replacement.isLoaded)
    }
}

@MainActor
private final class GatedLoadEngine: AIInferenceEngine {
    let kind: AIEnginePreference = .mlx
    private(set) var isLoaded = false
    private(set) var memoryUsage: Int64 = 0
    private var gate: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { gate != nil }

    func load(modelPath: String, modelSize: Int64) async throws {
        await withCheckedContinuation { gate = $0 }
        isLoaded = true
        memoryUsage = modelSize
    }

    func open() {
        gate?.resume()
        gate = nil
    }

    func unload() {
        isLoaded = false
        memoryUsage = 0
    }

    func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        "unused"
    }
}
