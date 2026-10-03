import Foundation

extension CloudAIService {
    /// Generate a deeper, prose explanation for a single scan result through
    /// the hosted Anthropic API. Mirrors `LocalAIService.explain` in shape so
    /// the explanation controller can treat Cloud as just another provider,
    /// but routes through `perform` so the monthly cap, usage ledger, and
    /// redaction all apply. The `rule` is accepted for protocol symmetry; the
    /// result already carries every field the prompt needs.
    public func explain(result: ScanResult, rule _: ScanRule) async throws -> AIExplanation {
        let configuration = configurationStore.load()
        let items = try CloudAIRedactor.items(
            from: [result],
            allowsFileContents: configuration.allowsFileContents,
            contentProvider: contentProvider
        )
        guard let item = items.first else {
            throw CloudAIError.disabled
        }
        let prompt = try CloudAIPromptBuilder.explanationPrompt(item: item)
        let completion = try await perform(
            feature: .explanation,
            prompt: prompt,
            metadata: ["item_count": "1"],
            configuration: configuration
        )
        let text = completion.response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIExplanation(text: text, source: .cloud)
    }

    /// Whether the Cloud provider can run a deeper explanation right now:
    /// enabled in settings, and — for Anthropic — an API key is on file.
    /// OpenAI-compatible endpoints may need no key (local servers), so enabled
    /// is enough there.
    public func canExplainDeeper() -> Bool {
        let configuration = configurationStore.load()
        guard configuration.isEnabled else { return false }
        if configuration.provider == .anthropic {
            return (try? keyStore(for: configuration).hasKey()) ?? false
        }
        return true
    }
}
