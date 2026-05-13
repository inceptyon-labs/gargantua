import Foundation
import Testing
@testable import GargantuaCore

@Suite("AIInferenceEngine narrate default")
@MainActor
struct AIInferenceEngineNarrateDefaultTests {

    @Test("Default implementation returns the deterministic template text")
    func defaultFallsBackToTemplate() async throws {
        let engine = NarrateFakeEngineNoOverride()
        let result = CleanupResult(itemResults: [
            CleanupItemResult(
                item: ScanResult(
                    id: "a",
                    name: "Chrome Cache",
                    path: "/Users/test/Library/Caches/Chrome",
                    size: 1_000,
                    safety: .safe,
                    confidence: 95,
                    explanation: "Test",
                    source: SourceAttribution(name: "Test"),
                    category: "test"
                ),
                succeeded: true,
                trashURL: URL(fileURLWithPath: "/tmp/a")
            ),
        ])

        let text = try await engine.narrate(cleanup: result)
        #expect(text == CleanupNarrativeTemplate.text(for: result))
    }
}

/// Engine that inherits the default `narrate` extension — used to pin the
/// default-implementation behavior.
@MainActor
private final class NarrateFakeEngineNoOverride: AIInferenceEngine {
    let kind: AIEnginePreference = .mlx
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    func load(modelPath: String, modelSize: Int64) async throws {
        isLoaded = true
        memoryUsage = modelSize
    }

    func unload() {
        isLoaded = false
        memoryUsage = 0
    }

    func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        ""
    }
}
