import Foundation

/// Stub inference engine targeting MLX Swift or `mlx-lm`.
///
/// Present so callers can wire up the `AIInferenceEngine` boundary and
/// toggle between engines via configuration ahead of the real MLX
/// integration. All inference operations throw
/// `AIInferenceEngineError.notImplemented` until the MLX dependency is
/// added (see PRD §6.2 Tier 1).
@MainActor
public final class MLXInferenceEngine: AIInferenceEngine {
    public private(set) var isLoaded: Bool = false
    public let memoryUsage: Int64 = 0

    public init() {}

    public func load(modelPath: String, modelSize: Int64) async throws {
        throw AIInferenceEngineError.notImplemented(engine: "MLX")
    }

    public func unload() {
        isLoaded = false
    }

    public func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        throw AIInferenceEngineError.notImplemented(engine: "MLX")
    }
}
