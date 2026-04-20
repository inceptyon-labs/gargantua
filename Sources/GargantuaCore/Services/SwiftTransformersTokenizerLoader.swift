import Foundation
import MLXLMCommon
import Tokenizers

/// Adapts `swift-transformers`' `AutoTokenizer` to `MLXLMCommon.TokenizerLoader`.
///
/// `MLXLMCommon` only ships the `TokenizerLoader` protocol; the concrete
/// implementation conventionally comes from `MLXHuggingFace`, which pulls in
/// the full HuggingFace hub client via a macro. We only need local-directory
/// loading (`ModelDownloadManager` stages the files), so this loader wraps
/// `Tokenizers.AutoTokenizer.from(modelFolder:)` directly and omits the hub
/// client — keeping the dependency footprint to `swift-transformers` alone.
public struct SwiftTransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return SwiftTransformersTokenizerBridge(upstream: upstream)
    }
}

/// Bridge from `Tokenizers.Tokenizer` (swift-transformers) to
/// `MLXLMCommon.Tokenizer`. Matches the adapter shape synthesized by
/// `#adaptHuggingFaceTokenizer` so behavior is equivalent to the macro path.
private struct SwiftTransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names the parameter `tokens:`; MLXLMCommon uses `tokenIds:`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
