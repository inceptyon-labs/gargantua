import Foundation

// Handler for the MCP `explain` tool. Shapes an `MCPExplainOutput` value
// produced by an injected `ExplainProvider` into the tool result envelope
// the dispatcher returns to clients.
//
// The handler itself is deliberately thin: input decoding (path-xor-item_id
// mutual exclusion) is enforced by `MCPExplainInput`, and the content of the
// explanation is supplied by the provider. This keeps the handler's test
// surface focused on envelope shaping + error sanitisation, and lets the
// provider swap from today's AI-free shell to an `AIInferenceEngine`-backed
// source without touching the handler.
//
// Scope: this Task (gargantua-o4ef) wires a default provider in
// `Sources/GargantuaMCP/main.swift` that returns a conservative "review"
// classification from filesystem metadata for `path` inputs and rejects
// `item_id` lookups as unsupported until a persisted-result bridge arrives.

/// Tool handler for `explain`.
public struct MCPExplainToolHandler: Sendable {

    /// Synchronous explanation provider. Throwing `MCPToolError.invalidParams`
    /// or `.internalError` propagates with the appropriate JSON-RPC code;
    /// any other thrown error is surfaced to the client as a tool-domain
    /// `.failure(...)` result.
    public typealias ExplainProvider = @Sendable (MCPExplainInput) throws -> MCPExplainOutput

    private let explainProvider: ExplainProvider
    private let log: MCPDispatcherLog?

    public init(
        explainProvider: @escaping ExplainProvider,
        log: MCPDispatcherLog? = nil
    ) {
        self.explainProvider = explainProvider
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects:
    /// `dispatcher.register(tool: .explain, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        let input = try arguments.decode(MCPExplainInput.self)

        let output: MCPExplainOutput
        do {
            output = try explainProvider(input)
        } catch let error as MCPToolError {
            throw error
        } catch {
            log?("explain handler error: \(error)")
            return .failure("Explain failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: Self.summary(for: output))
    }

    // MARK: - Helpers

    private static func summary(for output: MCPExplainOutput) -> String {
        let size = output.size.map { " (\($0))" } ?? ""
        return "\(output.name)\(size): \(output.safety) (\(output.confidence)%). "
            + output.explanation
    }
}
