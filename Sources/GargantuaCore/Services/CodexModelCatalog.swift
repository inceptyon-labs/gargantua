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

/// Static catalog of Codex models the settings picker offers.
///
/// Live discovery is not currently possible:
///   - `codex` CLI has no `list-models` subcommand.
///   - The OAuth access token stored in `~/.codex/auth.json` lacks the
///     `api.model.read` scope (ChatGPT Plus tokens are for inference
///     only), so calling OpenAI's `/v1/models` returns 403.
///   - The `OPENAI_API_KEY` field in that file is a placeholder Codex
///     writes for backward compatibility and returns 401.
///
/// The actual valid list lives compiled into the native Codex binary
/// (`.../codex/codex`, ~190 MB) — this list is extracted from there.
/// Bump when OpenAI ships a new tier; the selector still falls through
/// to a "(custom)" entry for any value the user has saved that isn't
/// here, so an out-of-date catalog never silently overrides their
/// choice. A v2 could add a user-supplied OpenAI API key field, which
/// would unlock live `/v1/models` fetching.
public enum CodexModelCatalog {
    /// Current tiers in display order (newest first).
    public static let bakedInModels: [CodexModel] = [
        CodexModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        CodexModel(id: "gpt-5.4", displayName: "GPT-5.4"),
        CodexModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
        CodexModel(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
        CodexModel(id: "gpt-5.2", displayName: "GPT-5.2"),
    ]
}
