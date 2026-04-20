import Foundation
import Testing
@testable import GargantuaCore

/// End-to-end smoke across `ModelDownloadManager.defaultModel` → `MLXInferenceEngine`
/// → `LocalAIService.explain`. Opt-in: skipped unless `GARGANTUA_MLX_SMOKE=1` is
/// set (so CI stays fast and doesn't need 680 MB of weights on disk). Proves
/// that a user who clicks "Download Model" in Settings and then asks for an
/// explanation actually gets AI-generated prose, not the YAML fallback.
@Suite("MLX explain smoke (opt-in)")
@MainActor
struct MLXExplainSmokeTests {

    nonisolated private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GARGANTUA_MLX_SMOKE"] == "1"
    }

    @Test("LocalAIService produces AI-sourced text against the staged default model",
          .disabled(if: !MLXExplainSmokeTests.isEnabled))
    func explainProducesAISourcedText() async throws {
        // 1. Verify the default model is actually staged on this machine.
        //    If it isn't, tell the user how to stage it rather than silently
        //    falling back to the YAML rule.
        let manager = ModelDownloadManager()
        guard case .downloaded(let path, let size) = manager.state else {
            Issue.record("""
                Default model is not staged. Click \"Download Model\" in Settings \
                or run the download flow, then re-run with GARGANTUA_MLX_SMOKE=1. \
                Expected: \(ModelDownloadManager.defaultModel.id) at \
                \(ModelDownloadManager.modelsDirectory.appendingPathComponent(ModelDownloadManager.defaultModel.id).path)
                """)
            return
        }
        #expect(size > 0, "Staged model size should be non-zero")
        #expect(path.contains(ModelDownloadManager.defaultModel.id),
                "State path should point at the default model directory")

        // 2. Build a real engine and a service wired to the real download
        //    manager. Short maxTokens keeps the test snappy (~seconds, not
        //    tens of seconds) while still exercising prompt → generate → text.
        let engine = MLXInferenceEngine(maxNewTokens: 64)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        #expect(service.isModelAvailable, "Service should see the staged model as available")

        // 3. Synthesize a scan result + rule — the prompt builder only reads
        //    field values, not on-disk content, so the actual path doesn't
        //    need to exist.
        let rule = ScanRule(
            id: "smoke_rule",
            name: "Chrome Browser Cache",
            paths: ["~/Library/Caches/Google/Chrome"],
            safety: .safe,
            confidence: 98,
            explanation: "YAML fallback text — AI explanation should differ from this.",
            source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
            regenerates: true,
            regenerateCommand: nil,
            category: "browser_cache",
            tags: ["browser", "cache"]
        )
        let result = ScanResult(
            id: "smoke_result_001",
            name: "Chrome Browser Cache",
            path: "/Users/smoke/Library/Caches/Google/Chrome",
            size: 500_000_000,
            safety: .safe,
            confidence: 98,
            explanation: "YAML fallback text — AI explanation should differ from this.",
            source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
            category: "browser_cache",
            tags: ["browser", "cache"],
            regenerates: true
        )

        // 4. The critical assertion: source must be .ai. If the engine failed
        //    to load or to generate, LocalAIService would silently return
        //    .rule with the YAML string — that's safe for production but
        //    would mask a broken engine here. Fail loudly instead.
        let explanation = try await service.explain(result: result, rule: rule)

        #expect(explanation.source == .ai,
                "Explain should return AI-generated text, not the YAML rule fallback. Got: \(explanation.text)")
        #expect(!explanation.text.isEmpty, "AI explanation text should be non-empty")
        #expect(explanation.text != rule.explanation,
                "AI explanation should differ from the YAML fallback string")
        // Sanity: a few words, not a single token.
        let wordCount = explanation.text.split(whereSeparator: \.isWhitespace).count
        #expect(wordCount >= 5, "Expected at least a short sentence; got '\(explanation.text)'")

        // 5. Ensure the service transitioned through .ready and that explicit
        //    unload resets state — mirrors what the idle timer would do.
        #expect(service.lifecycleState == .ready)
        #expect(service.modelMemoryUsage > 0)
        service.unloadModel()
        #expect(service.lifecycleState == .unloaded)
        #expect(service.modelMemoryUsage == 0)
    }
}
