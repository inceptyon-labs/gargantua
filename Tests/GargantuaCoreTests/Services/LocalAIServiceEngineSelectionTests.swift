import Foundation
import Testing

@testable import GargantuaCore

@Suite("LocalAIService engine selection")
struct LocalAIServiceEngineSelectionTests {

    @Test("AIEnginePreference defaults to Template and persists MLX")
    func enginePreferenceStorage() throws {
        let suiteName = "gargantua-ai-engine-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AIEnginePreference.stored(in: defaults) == .template)

        AIEnginePreference.mlx.store(in: defaults)

        #expect(AIEnginePreference.stored(in: defaults) == .mlx)
    }

    @Test("MLX selected with model present returns MLX engine")
    func engineFactoryUsesMLXWhenModelPresent() throws {
        let model = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: model.url) }

        let selection = AIInferenceEngineFactory.select(
            preference: .mlx,
            modelState: .downloaded(path: model.url.path, size: model.size)
        )

        #expect(selection.kind == .mlx)
        #expect(selection.isFallback == false)
        #expect(selection.engine is MLXInferenceEngine)
    }

    @Test("MLX selected with no model falls back to Template engine")
    func engineFactoryFallsBackWithoutModel() {
        let selection = AIInferenceEngineFactory.select(
            preference: .mlx,
            modelState: .notDownloaded
        )

        #expect(selection.kind == .template)
        #expect(selection.isFallback == true)
        #expect(selection.engine is TemplateInferenceEngine)
    }

    @Test("Template selected uses Template engine even when MLX model exists")
    func engineFactoryHonorsTemplatePreference() throws {
        let model = try makeTempModelDirectory()
        defer { try? FileManager.default.removeItem(at: model.url) }

        let selection = AIInferenceEngineFactory.select(
            preference: .template,
            modelState: .downloaded(path: model.url.path, size: model.size)
        )

        #expect(selection.kind == .template)
        #expect(selection.isFallback == false)
        #expect(selection.engine is TemplateInferenceEngine)
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
