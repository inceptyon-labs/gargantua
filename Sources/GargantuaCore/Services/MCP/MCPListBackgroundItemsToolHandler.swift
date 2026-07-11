import Foundation

// Handler for the MCP `list_background_items` tool. Shapes a
// `BackgroundItemScan` into the `MCPListBackgroundItemsOutput` payload —
// read-only launchd agents/daemons/login items with safety classification,
// evidence reasons, runtime state, and explanations.
//
// An optional exact-match `label` argument narrows the result to a single
// item ("inspect" mode). A miss is a successful empty result, not a failure —
// the client asked a valid question and got a valid (empty) answer.
//
// Production wiring in `Sources/GargantuaMCP/main.swift` feeds this handler
// from `DefaultBackgroundItemScanner`, the same scanner the Background Items
// review pane uses.

/// Tool handler for `list_background_items`.
public struct MCPListBackgroundItemsToolHandler: Sendable {

    /// Synchronous Background Items scan provider. Throwing `MCPToolError`
    /// propagates with the appropriate JSON-RPC code; any other thrown error
    /// is surfaced to the client as a tool-domain `.failure(...)` result.
    public typealias ScanProvider = @Sendable () throws -> BackgroundItemScan

    private let scanProvider: ScanProvider
    private let log: MCPDispatcherLog?

    public init(
        scanProvider: @escaping ScanProvider,
        log: MCPDispatcherLog? = nil
    ) {
        self.scanProvider = scanProvider
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects:
    /// `dispatcher.register(tool: .listBackgroundItems, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        let input = try arguments.decode(MCPListBackgroundItemsInput.self)

        let scan: BackgroundItemScan
        do {
            scan = try scanProvider()
        } catch let error as MCPToolError {
            throw error
        } catch {
            log?("list_background_items handler error: \(error)")
            return .failure("List background items failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        let filtered: [BackgroundItem]
        if let label = input.label {
            filtered = scan.items.filter { $0.label == label }
        } else {
            filtered = scan.items
        }

        let output = Self.makeOutput(from: scan, items: filtered)
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: Self.summary(for: output, filterLabel: input.label))
    }

    // MARK: - Helpers

    static func makeOutput(from scan: BackgroundItemScan, items: [BackgroundItem]) -> MCPListBackgroundItemsOutput {
        MCPListBackgroundItemsOutput(
            items: items.map(itemSummary(for:)),
            loginItemsNeedPrivileges: scan.loginItemsNeedPrivileges,
            unparseableCount: scan.unparseableCount
        )
    }

    private static func itemSummary(for item: BackgroundItem) -> MCPBackgroundItemSummary {
        MCPBackgroundItemSummary(
            label: item.label,
            displayName: item.displayName,
            source: sourceString(for: item.source),
            safety: item.safety.rawValue,
            // `reasons` is a `Set` — sort so repeated calls produce identical
            // wire output instead of leaking Swift's nondeterministic Set order.
            reasons: item.reasons.map(\.rawValue).sorted(),
            explanation: item.explanation,
            plistPath: item.plistPath,
            executablePath: item.executablePath,
            isOrphaned: item.isOrphaned,
            runtime: item.runtime.map(runtimeSummary(for:))
        )
    }

    private static func runtimeSummary(for state: LaunchdRuntimeState) -> MCPBackgroundItemRuntime {
        MCPBackgroundItemRuntime(
            isLoaded: state.isLoaded,
            pid: state.pid,
            lastExitStatus: state.lastExitStatus,
            disabledOverride: state.disabledOverride
        )
    }

    private static func sourceString(for source: BackgroundItemSource) -> String {
        switch source {
        case .userLaunchAgent: "user_launch_agent"
        case .systemLaunchAgent: "system_launch_agent"
        case .launchDaemon: "launch_daemon"
        case .startupItem: "startup_item"
        case .loginItem: "login_item"
        }
    }

    private static func summary(for output: MCPListBackgroundItemsOutput, filterLabel: String?) -> String {
        if let filterLabel, output.items.isEmpty {
            return "No item matching '\(filterLabel)'."
        }
        let safe = output.items.filter { $0.safety == SafetyLevel.safe.rawValue }.count
        let review = output.items.filter { $0.safety == SafetyLevel.review.rawValue }.count
        let protectedCount = output.items.filter { $0.safety == SafetyLevel.protected_.rawValue }.count
        return "\(output.items.count) background items (\(safe) safe, \(review) review, \(protectedCount) protected)."
    }
}
