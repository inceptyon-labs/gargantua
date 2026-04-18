import Foundation

/// An inference engine produces explanation text from structured scan inputs.
///
/// This is the boundary between `LocalAIService` (lifecycle, fallback, idle
/// unload) and the underlying inference backend (MLX Swift, `mlx-lm`
/// subprocess, or a deterministic template). `LocalAIService` owns the
/// engine and tells it when to load, unload, and generate; the engine owns
/// the model weights and the prompting strategy.
///
/// Conformers must be safe to call on the main actor and should release
/// any held memory from `unload()`.
@MainActor
public protocol AIInferenceEngine: AnyObject, Sendable {
    /// Whether the engine is currently holding model state in memory.
    var isLoaded: Bool { get }

    /// Approximate memory held by the engine, in bytes. Zero when unloaded.
    var memoryUsage: Int64 { get }

    /// Load model weights from disk into memory.
    ///
    /// - Parameters:
    ///   - modelPath: Absolute path to the on-disk model file.
    ///   - modelSize: Size of the model file in bytes (pre-validated by caller).
    func load(modelPath: String, modelSize: Int64) async throws

    /// Release all model state from memory.
    func unload()

    /// Generate explanation text for a scan result using the loaded model.
    ///
    /// Precondition: `isLoaded` is true. Calling on an unloaded engine is
    /// a programmer error — `LocalAIService` guards this.
    func generate(for result: ScanResult, rule: ScanRule) async throws -> String
}

/// Errors specific to inference engines. `LocalAIService` wraps these in
/// `AIServiceError.loadFailed` when surfacing to callers.
public enum AIInferenceEngineError: Error, LocalizedError {
    /// The engine is a stub and has no real inference implementation yet.
    case notImplemented(engine: String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let engine):
            return "\(engine) inference is not yet available."
        }
    }
}
