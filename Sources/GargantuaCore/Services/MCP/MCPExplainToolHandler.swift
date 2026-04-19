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

// MARK: - Default filesystem-backed provider

public extension MCPExplainToolHandler {
    /// Default AI-free `ExplainProvider` backed by filesystem metadata.
    ///
    /// Behavior:
    /// - `item_id` inputs throw `MCPToolError.invalidParams` (lookup not yet
    ///   supported; a persisted scan-result bridge replaces this later).
    /// - Missing, empty, or non-absolute `path` inputs throw
    ///   `MCPToolError.invalidParams`. Absolute-only is enforced because
    ///   `MCPPhase2Tools.explain` advertises `path` as an "Absolute filesystem
    ///   path"; accepting relative paths would resolve against the MCP
    ///   process's current working directory and produce surprising results
    ///   depending on launch context.
    /// - Missing or inaccessible paths (file not found, permission denied)
    ///   return a shell response with no `size`/`lastAccessed` rather than
    ///   erroring. The shell's contract is to always render a conservative
    ///   `"review"` classification for any accepted input; the AI-backed
    ///   provider that replaces this shell will distinguish "unknown
    ///   metadata" from "path not found" explicitly.
    /// - Size is omitted for directories (`.size` returns the inode size, not
    ///   the recursive total) to avoid reporting a misleading small number.
    /// - `lastAccessed` maps to `.modificationDate`: APFS often disables the
    ///   true content-access time, and modification time is the closest
    ///   always-available fallback.
    ///
    /// Uses `FileManager.default` directly because `FileManager` is not
    /// `Sendable` and this closure is `@Sendable`. Tests exercise it with
    /// real temporary files.
    static func defaultFilesystemProvider() -> ExplainProvider {
        return { input in
            if input.itemId != nil {
                throw MCPToolError.invalidParams(
                    "item_id lookup is not yet supported via MCP; supply an absolute filesystem path instead."
                )
            }
            guard let path = input.path, !path.isEmpty else {
                // `MCPExplainInput` already enforces path-xor-item_id at
                // decode, so this branch is defensive against a future
                // input-shape change that might let both be nil through.
                throw MCPToolError.invalidParams("explain requires a non-empty path.")
            }
            guard path.hasPrefix("/") else {
                throw MCPToolError.invalidParams(
                    "explain requires an absolute filesystem path (starting with '/')."
                )
            }

            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent

            var size: String?
            var lastAccessed: Date?
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
                let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
                if !isDirectory, let bytes = attributes[.size] as? NSNumber {
                    size = AlertItem.formatBytes(Int64(clamping: bytes.int64Value))
                }
                if let modified = attributes[.modificationDate] as? Date {
                    lastAccessed = modified
                }
            }

            return MCPExplainOutput(
                name: name,
                safety: "review",
                confidence: 50,
                explanation: "AI-backed analysis is not yet wired; this item is flagged 'review' by default. Inspect before cleanup.",
                size: size,
                lastAccessed: lastAccessed
            )
        }
    }
}
