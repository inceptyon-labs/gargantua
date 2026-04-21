import Foundation
import Testing
import Tokenizers
@testable import GargantuaCore

/// Opt-in latency and memory smoke coverage for the production MLX backend.
///
/// Run locally with:
///   GARGANTUA_MLX_PERF_SMOKE=1 GARGANTUA_MLX_PERF_RUNS=3 Scripts/test.sh --filter recordsBackendEnvelope
///
/// The test prints machine-readable `MLX_PERF_*` lines so the backend design
/// doc can be updated with fresh measurements after model or backend changes.
@Suite("MLX backend performance smoke (opt-in)")
@MainActor
struct MLXBackendPerformanceSmokeTests {
    nonisolated private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GARGANTUA_MLX_PERF_SMOKE"] == "1"
    }

    @Test("Records cold load, warm generate latency, resident memory, and output tokens",
          .disabled(if: !MLXBackendPerformanceSmokeTests.isEnabled))
    func recordsBackendEnvelope() async throws {
        let modelDirectory = try Self.resolveModelDirectory()
        let runsPerCase = Self.runsPerCase
        let maxNewTokens = Self.maxNewTokens
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: modelDirectory)
        let engine = MLXInferenceEngine(maxNewTokens: maxNewTokens)

        let (_, coldLoadSeconds) = try await Self.measureSeconds {
            try await engine.load(modelPath: modelDirectory.path, modelSize: 0)
        }
        #expect(engine.isLoaded)
        #expect(engine.memoryUsage > 0)

        let memoryAfterLoad = engine.memoryUsage
        let cases = Self.representativeCases()
        var allLatencies: [Double] = []

        print("""
            MLX_PERF_SUMMARY model_dir=\(modelDirectory.path) cases=\(cases.count) runs_per_case=\(runsPerCase) max_new_tokens=\(maxNewTokens) cold_load_s=\(Self.formatSeconds(coldLoadSeconds)) memory_bytes=\(memoryAfterLoad) memory_mib=\(Self.formatMiB(memoryAfterLoad))
            """)

        for smokeCase in cases {
            var latencies: [Double] = []
            var tokenCounts: [Int] = []

            for _ in 0..<runsPerCase {
                let (text, generateSeconds) = try await Self.measureSeconds {
                    try await engine.generate(for: smokeCase.result, rule: smokeCase.rule)
                }

                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                latencies.append(generateSeconds)
                allLatencies.append(generateSeconds)
                tokenCounts.append(tokenizer.encode(text: text, addSpecialTokens: false).count)
            }

            print("""
                MLX_PERF_CASE id=\(smokeCase.rule.id) category=\(smokeCase.rule.category) safety=\(smokeCase.rule.safety.rawValue) p50_s=\(Self.formatSeconds(Self.percentile(latencies, 0.50))) p95_s=\(Self.formatSeconds(Self.percentile(latencies, 0.95))) token_counts=\(tokenCounts.map(String.init).joined(separator: ","))
                """)
        }

        print("""
            MLX_PERF_TOTAL samples=\(allLatencies.count) p50_s=\(Self.formatSeconds(Self.percentile(allLatencies, 0.50))) p95_s=\(Self.formatSeconds(Self.percentile(allLatencies, 0.95)))
            """)

        #expect(memoryAfterLoad < LocalAIService.maxModelMemory)

        engine.unload()
        #expect(!engine.isLoaded)
        #expect(engine.memoryUsage == 0)
    }

    private static var runsPerCase: Int {
        let raw = ProcessInfo.processInfo.environment["GARGANTUA_MLX_PERF_RUNS"]
        return max(Int(raw ?? "") ?? 3, 1)
    }

    private static var maxNewTokens: Int {
        let raw = ProcessInfo.processInfo.environment["GARGANTUA_MLX_PERF_MAX_TOKENS"]
        return max(Int(raw ?? "") ?? 180, 1)
    }

    private static func resolveModelDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["GARGANTUA_MLX_PERF_MODEL_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let manager = ModelDownloadManager()
        guard case .downloaded(let path, _) = manager.state else {
            throw SmokeError.modelNotStaged(
                ModelDownloadManager.modelsDirectory
                    .appendingPathComponent(ModelDownloadManager.defaultModel.id, isDirectory: true)
                    .path
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func measureSeconds<T>(
        _ operation: () async throws -> T
    ) async throws -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return (value, Double(end - start) / 1_000_000_000)
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(quantile * Double(sorted.count))) - 1))
        return sorted[index]
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func formatMiB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private static func representativeCases() -> [SmokeCase] {
        [
            makeCase(
                id: "chrome_cache",
                name: "Chrome Browser Cache",
                path: "/Users/smoke/Library/Caches/Google/Chrome",
                size: 500_000_000,
                safety: .safe,
                confidence: 98,
                explanation: "Browser cache files regenerated automatically on next visit. No user data lost.",
                source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome", verifySignature: true),
                regenerates: true,
                category: "browser_cache",
                tags: ["browser", "cache"]
            ),
            makeCase(
                id: "chrome_local_storage",
                name: "Chrome Local Storage",
                path: "/Users/smoke/Library/Application Support/Google/Chrome/Default/Local Storage",
                size: 75_000_000,
                safety: .review,
                confidence: 75,
                explanation: "Website local storage may contain login tokens and preferences. Review before removing.",
                source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome", verifySignature: true),
                regenerates: false,
                category: "browser_data",
                tags: ["browser", "user_data"]
            ),
            makeCase(
                id: "xcode_derived_data",
                name: "Xcode Derived Data",
                path: "/Users/smoke/Library/Developer/Xcode/DerivedData",
                size: 4_500_000_000,
                safety: .safe,
                confidence: 98,
                explanation: "Build intermediates and indexes. Rebuilt automatically on next build.",
                source: SourceAttribution(name: "Xcode", bundleID: "com.apple.dt.Xcode", verifySignature: true),
                regenerates: true,
                regenerateCommand: "xcodebuild",
                category: "dev_artifacts",
                tags: ["developer", "build_cache"]
            ),
            makeCase(
                id: "docker_data",
                name: "Docker Application Data",
                path: "/Users/smoke/Library/Containers/com.docker.docker/Data",
                size: 12_000_000_000,
                safety: .review,
                confidence: 75,
                explanation: "Docker configuration and state data. Volumes may contain important data.",
                source: SourceAttribution(name: "Docker Desktop", bundleID: "com.docker.docker", verifySignature: true),
                regenerates: false,
                category: "docker",
                tags: ["developer", "containers"]
            ),
            makeCase(
                id: "system_logs",
                name: "System Log Files",
                path: "/Users/smoke/Library/Logs",
                size: 350_000_000,
                safety: .safe,
                confidence: 90,
                explanation: "Application log files. Useful for debugging but safe to remove when not needed.",
                source: SourceAttribution(name: "macOS"),
                regenerates: true,
                category: "system_logs",
                tags: ["system", "logs"]
            ),
            makeCase(
                id: "generic_application_support",
                name: "Application Support folder",
                path: "/Users/smoke/Library/Application Support/Acme Notes",
                size: 180_000_000,
                safety: .review,
                confidence: 92,
                explanation: "App-written support data; regenerated if the app is reinstalled.",
                source: SourceAttribution(name: "Acme Notes"),
                regenerates: true,
                category: "support_files",
                tags: ["generic", "support", "remnant"]
            ),
        ]
    }

    private static func makeCase(
        id: String,
        name: String,
        path: String,
        size: Int64,
        safety: SafetyLevel,
        confidence: Int,
        explanation: String,
        source: SourceAttribution,
        regenerates: Bool,
        regenerateCommand: String? = nil,
        category: String,
        tags: [String]
    ) -> SmokeCase {
        let rule = ScanRule(
            id: id,
            name: name,
            paths: [path],
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: source,
            regenerates: regenerates,
            regenerateCommand: regenerateCommand,
            category: category,
            tags: tags
        )
        let result = ScanResult(
            id: "\(id)_smoke",
            name: name,
            path: path,
            size: size,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: source,
            category: category,
            tags: tags,
            regenerates: regenerates,
            regenerateCommand: regenerateCommand
        )
        return SmokeCase(rule: rule, result: result)
    }
}

private struct SmokeCase {
    let rule: ScanRule
    let result: ScanResult
}

private enum SmokeError: LocalizedError {
    case modelNotStaged(String)

    var errorDescription: String? {
        switch self {
        case .modelNotStaged(let path):
            return "Default MLX model is not staged at \(path). Download it in Settings or set GARGANTUA_MLX_PERF_MODEL_DIR."
        }
    }
}
