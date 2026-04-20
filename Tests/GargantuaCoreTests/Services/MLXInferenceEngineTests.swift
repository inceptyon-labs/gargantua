import Foundation
import Testing
@testable import GargantuaCore

@Suite("MLXInferenceEngine")
@MainActor
struct MLXInferenceEngineTests {

    // MARK: - Fixtures

    private func makeRule() -> ScanRule {
        ScanRule(
            id: "chrome_cache",
            name: "Chrome Browser Cache",
            paths: ["~/Library/Caches/Google/Chrome"],
            safety: .safe,
            confidence: 98,
            explanation: "Chrome rebuilds this cache on launch; safe to delete.",
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

    // MARK: - Prompt builder (pure, no MLX)

    @Test("Prompt includes item name, path, category, safety, and rule explanation")
    func promptIncludesKeyFields() {
        let prompt = MLXInferenceEngine.buildPrompt(for: makeResult(), rule: makeRule())

        #expect(prompt.contains("Chrome Browser Cache"))
        #expect(prompt.contains("/Users/test/Library/Caches/Google/Chrome"))
        #expect(prompt.contains("browser cache"))
        #expect(prompt.contains("safe"))
        #expect(prompt.contains("Chrome rebuilds this cache on launch"))
    }

    @Test("Prompt reflects regenerates:false when rule says so")
    func promptReflectsNonRegenerating() {
        let result = ScanResult(
            id: "x",
            name: "Some File",
            path: "/tmp/x",
            size: 1024,
            safety: .review,
            confidence: 50,
            explanation: "",
            source: SourceAttribution(name: "Unknown", bundleID: nil),
            category: "misc",
            tags: [],
            regenerates: false
        )
        let prompt = MLXInferenceEngine.buildPrompt(for: result, rule: makeRule())
        #expect(prompt.contains("Regenerates: no"))
    }

    @Test("Prompt includes regenerate command when present")
    func promptIncludesRegenerateCommand() {
        let result = ScanResult(
            id: "x",
            name: "Xcode Derived Data",
            path: "/tmp/derived",
            size: 1024,
            safety: .safe,
            confidence: 99,
            explanation: "",
            source: SourceAttribution(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
            category: "build_artifact",
            tags: [],
            regenerates: true,
            regenerateCommand: "xcodebuild -scheme MyApp build"
        )
        let prompt = MLXInferenceEngine.buildPrompt(for: result, rule: makeRule())
        #expect(prompt.contains("xcodebuild -scheme MyApp build"))
    }

    // MARK: - Path resolution

    @Test("resolveModelDirectory returns a directory URL as-is")
    func resolveAcceptsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-mlx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = try MLXInferenceEngine.resolveModelDirectory(dir.path)
        #expect(resolved.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test("resolveModelDirectory uses parent when given a file")
    func resolveAcceptsFileAndUsesParent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-mlx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("weights.safetensors")
        try Data("fake".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = try MLXInferenceEngine.resolveModelDirectory(file.path)
        #expect(resolved.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test("resolveModelDirectory throws on missing path")
    func resolveThrowsOnMissing() {
        let missing = "/tmp/gargantua-nothing-here-\(UUID().uuidString)"
        #expect(throws: MLXInferenceError.self) {
            _ = try MLXInferenceEngine.resolveModelDirectory(missing)
        }
    }

    // MARK: - Directory validation

    @Test("validateModelDirectory reports missing config.json")
    func validateReportsMissingConfig() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // tokenizer + weights present, but no config.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data("fake".utf8).write(to: dir.appendingPathComponent("weights.safetensors"))

        #expect(throws: MLXInferenceError.self) {
            try MLXInferenceEngine.validateModelDirectory(dir)
        }
    }

    @Test("validateModelDirectory reports missing tokenizer")
    func validateReportsMissingTokenizer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("fake".utf8).write(to: dir.appendingPathComponent("weights.safetensors"))

        #expect(throws: MLXInferenceError.self) {
            try MLXInferenceEngine.validateModelDirectory(dir)
        }
    }

    @Test("validateModelDirectory reports missing weights")
    func validateReportsMissingWeights() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))

        #expect(throws: MLXInferenceError.self) {
            try MLXInferenceEngine.validateModelDirectory(dir)
        }
    }

    @Test("validateModelDirectory accepts a well-formed directory")
    func validateAcceptsGoodDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data("fake".utf8).write(to: dir.appendingPathComponent("model.safetensors"))

        // Should not throw.
        try MLXInferenceEngine.validateModelDirectory(dir)
    }

    @Test("validateModelDirectory accepts tokenizer_config.json as tokenizer marker")
    func validateAcceptsTokenizerConfigOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer_config.json"))
        try Data("fake".utf8).write(to: dir.appendingPathComponent("model.safetensors"))

        try MLXInferenceEngine.validateModelDirectory(dir)
    }

    // MARK: - Engine lifecycle (no model required)

    @Test("Initial state is unloaded with zero memory")
    func initialState() {
        let engine = MLXInferenceEngine()
        #expect(engine.isLoaded == false)
        #expect(engine.memoryUsage == 0)
    }

    @Test("unload() is safe on an unloaded engine")
    func unloadOnUnloaded() {
        let engine = MLXInferenceEngine()
        engine.unload()
        #expect(engine.isLoaded == false)
        #expect(engine.memoryUsage == 0)
    }

    @Test("load throws on an incomplete directory")
    func loadThrowsOnIncompleteDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Only drop config.json — tokenizer + weights missing.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))

        let engine = MLXInferenceEngine()
        await #expect(throws: MLXInferenceError.self) {
            try await engine.load(modelPath: dir.path, modelSize: 0)
        }
        #expect(engine.isLoaded == false)
        #expect(engine.memoryUsage == 0)
    }

    // MARK: - Happy-path integration (env-gated)

    /// End-to-end load + generate against a real MLX model directory. Skipped
    /// in CI; run locally by setting `GARGANTUA_MLX_MODEL_DIR` to a
    /// `mlx-community/Llama-3.2-1B-Instruct-4bit`-style directory (or any
    /// HF-layout MLX LM model).
    @Test("Integration: load + generate + unload against a real model",
          .disabled(if: ProcessInfo.processInfo.environment["GARGANTUA_MLX_MODEL_DIR"] == nil))
    func integrationHappyPath() async throws {
        let path = ProcessInfo.processInfo.environment["GARGANTUA_MLX_MODEL_DIR"]!
        let engine = MLXInferenceEngine(maxNewTokens: 64)

        try await engine.load(modelPath: path, modelSize: 0)
        #expect(engine.isLoaded == true)
        #expect(engine.memoryUsage > 0, "memoryUsage should reflect resident weights")

        let text = try await engine.generate(for: makeResult(), rule: makeRule())
        #expect(!text.isEmpty, "generate should return non-empty text")

        engine.unload()
        #expect(engine.isLoaded == false)
        #expect(engine.memoryUsage == 0)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-mlx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
