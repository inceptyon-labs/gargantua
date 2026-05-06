import Foundation
import MLX
import MLXLLM
import MLXLMCommon

@MainActor
final class MLXLifecycleController {
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0
    private(set) var modelContainer: ModelContainer?

    func load(modelPath: String) async throws {
        let directory = try Self.resolveModelDirectory(modelPath)
        try Self.validateModelDirectory(directory)

        let baseline = MLX.Memory.activeMemory
        let tokenizerLoader = SwiftTransformersTokenizerLoader()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: tokenizerLoader
        )

        modelContainer = container
        let after = MLX.Memory.activeMemory
        memoryUsage = Int64(max(0, after - baseline))
        isLoaded = true
    }

    func unload() {
        let wasLoaded = isLoaded
        modelContainer = nil
        // Return cached buffers to the system allocator. Skip when the engine
        // was never loaded: that path touches MLX and forces Metal device init,
        // which fails until the release pipeline ships a compiled metallib.
        if wasLoaded {
            MLX.Memory.clearCache()
        }
        memoryUsage = 0
        isLoaded = false
    }

    /// Accepts either a directory path or a file path (whose parent is used).
    /// `ModelDownloadManager` currently stages a single file; that file's
    /// parent directory is not itself a HF-layout model root, so today this
    /// path will fail validation — a planned follow-up reworks the manager.
    static func resolveModelDirectory(_ modelPath: String) throws -> URL {
        let url = URL(fileURLWithPath: modelPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            throw MLXInferenceError.modelPathIsNotDirectory(modelPath)
        }
        if isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// Confirms the directory contains the minimum files MLX LM needs.
    static func validateModelDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) {
            missing.append("config.json")
        }
        let tokenizerJSON = directory.appendingPathComponent("tokenizer.json").path
        let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json").path
        if !fm.fileExists(atPath: tokenizerJSON) && !fm.fileExists(atPath: tokenizerConfig) {
            missing.append("tokenizer.json or tokenizer_config.json")
        }
        if let contents = try? fm.contentsOfDirectory(atPath: directory.path) {
            if !contents.contains(where: { $0.hasSuffix(".safetensors") }) {
                missing.append("*.safetensors")
            }
        } else {
            missing.append("*.safetensors")
        }
        guard missing.isEmpty else {
            throw MLXInferenceError.modelDirectoryIncomplete(
                directory: directory.path,
                missing: missing
            )
        }
    }
}
