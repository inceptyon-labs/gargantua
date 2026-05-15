import Foundation

/// One OpenAI Codex model option surfaced in the settings picker.
public struct CodexModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Static catalog of Codex models the settings picker offers. Unlike
/// the Anthropic catalog there's no public OpenAI `/v1/models`-style
/// endpoint the Codex CLI uses directly, so this list is maintained by
/// hand and bumped via the user's `~/.codex/config.toml` migration
/// table. The selector still supports custom overrides — any model the
/// user has saved that isn't here renders as "(custom)".
public enum CodexModelCatalog {
    /// Current tiers. Order is display order (newest first).
    public static let bakedInModels: [CodexModel] = [
        CodexModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        CodexModel(id: "gpt-5.4", displayName: "GPT-5.4"),
        CodexModel(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
        CodexModel(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
    ]
}
