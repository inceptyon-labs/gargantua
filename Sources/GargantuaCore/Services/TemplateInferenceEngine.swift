import Foundation

/// A deterministic inference engine that generates explanations from a
/// template using structured rule/result metadata.
///
/// This is the default engine used until real MLX or `mlx-lm` inference is
/// wired up. It memory-maps the model file (so memory accounting and idle
/// unload behave the same as a real engine would) but ignores the weights
/// and returns template text derived from the YAML rule. Output is still
/// labeled as `.ai` by `LocalAIService` — swapping in a real engine gives
/// genuinely generated text without changing the call site.
@MainActor
public final class TemplateInferenceEngine: AIInferenceEngine {
    public let kind: AIEnginePreference = .template
    public private(set) var isLoaded: Bool = false
    public private(set) var memoryUsage: Int64 = 0

    private var mappedData: Data?

    public init() {}

    public func load(modelPath: String, modelSize: Int64) async throws {
        let url = URL(fileURLWithPath: modelPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            mappedData = nil
            memoryUsage = modelSize
            isLoaded = true
            return
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        mappedData = data
        memoryUsage = Int64(data.count)
        isLoaded = true
    }

    public func unload() {
        mappedData = nil
        memoryUsage = 0
        isLoaded = false
    }

    public func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        if rule.category == "process_triage" {
            return "\(result.name) was selected for process triage because \(rule.explanation) "
                + "Recommended next step: investigate before stopping it; "
                + "stopping a process can disrupt the app that owns it."
        }
        if rule.category == "background_item_triage" {
            return "\(result.name) was selected for background-item triage because \(rule.explanation) Recommended next step: investigate first; disable before removing any launch item."
        }

        var parts: [String] = []
        parts.append("\(result.name) is a \(rule.category.replacingOccurrences(of: "_", with: " ")) item")
        parts.append("created by \(result.source.name).")

        if result.regenerates {
            if let cmd = result.regenerateCommand {
                parts.append("It can be regenerated with `\(cmd)`.")
            } else {
                parts.append("It regenerates automatically.")
            }
        }

        parts.append("Safety: \(result.safety.rawValue) (\(result.confidence)% confidence).")
        parts.append(rule.explanation)

        return parts.joined(separator: " ")
    }
}
