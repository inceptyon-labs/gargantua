import Foundation

// Handler for the MCP `list_app_updates` tool. Read-only: shapes the rows of
// the same update check the App Updates page runs into an
// `MCPListAppUpdatesOutput`. Nothing is downloaded or installed.
//
// The handler is synchronous to match `MCPToolHandler`; the async check is
// bridged to sync at the call site in `Sources/GargantuaMCP/main.swift`.

/// Tool handler for `list_app_updates`.
public struct MCPListAppUpdatesToolHandler: Sendable {

    /// Runs the update check. Throwing `MCPToolError` propagates with its
    /// JSON-RPC code; any other error becomes a tool-domain `.failure(...)`.
    public typealias RowsProvider = @Sendable () throws -> [AppReleaseRow]

    /// Wire cap, like `list_background_items`; `totalItems` carries the real count.
    public static let maxItemsInWireOutput = 100

    private let rowsProvider: RowsProvider
    private let log: MCPDispatcherLog?

    public init(rowsProvider: @escaping RowsProvider, log: MCPDispatcherLog? = nil) {
        self.rowsProvider = rowsProvider
        self.log = log
    }

    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        let input = try arguments.decode(MCPListAppUpdatesInput.self)

        let rows: [AppReleaseRow]
        do {
            rows = try rowsProvider()
        } catch let error as MCPToolError {
            throw error
        } catch {
            log?("list_app_updates handler error: \(error)")
            return .failure("List app updates failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        let available = rows.filter { Self.hasUpdate($0) }
        let selected: [AppReleaseRow]
        if let bundleID = input.bundleID {
            selected = rows.filter { $0.app.bundleID == bundleID }
        } else if input.includeAll == true {
            selected = rows
        } else {
            selected = available
        }

        let output = MCPListAppUpdatesOutput(
            items: selected.prefix(Self.maxItemsInWireOutput).map(Self.summary(for:)),
            totalItems: selected.count,
            availableCount: available.count
        )
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        var text = "\(available.count) app updates available (of \(rows.count) apps checked)"
        if let bundleID = input.bundleID, selected.isEmpty {
            text = "No app matching '\(bundleID)'. " + text
        }
        if output.items.count < selected.count {
            text += ". Showing first \(output.items.count) of \(selected.count) rows"
        }
        return .structured(payload, summary: text + ".")
    }

    // MARK: - Helpers

    private static func hasUpdate(_ row: AppReleaseRow) -> Bool {
        row.availableCandidate != nil
    }

    private static func summary(for row: AppReleaseRow) -> MCPAppUpdateSummary {
        var status: String
        var candidate: AppReleaseCandidate?
        var brewToken: String?
        switch row.status {
        case .available(let found, let strategy):
            candidate = found
            status = "available"
            switch strategy {
            case .linkOnly: status = "link_only"
            case .brewUpgrade(let token): brewToken = token
            case .inPlace, .openAppStore: break
            }
        case .upToDate(let latest):
            candidate = latest
            status = "up_to_date"
        case .ignored: status = "ignored"
        case .skippedVersion: status = "skipped"
        case .untracked: status = "untracked"
        case .failed: status = "failed"
        }
        let isUpdate = row.availableCandidate != nil
        return MCPAppUpdateSummary(
            bundleID: row.app.bundleID,
            name: row.app.name,
            installedVersion: row.app.version.description,
            status: status,
            availableVersion: isUpdate ? candidate?.displayVersion : nil,
            source: candidate.map { sourceString(for: $0.source) },
            brewManagedToken: brewToken,
            directDownload: candidate?.downloadURL != nil
        )
    }

    private static func sourceString(for source: AppReleaseSourceKind) -> String {
        switch source {
        case .catalog: "catalog"
        case .sparkle: "sparkle"
        case .homebrewCask: "homebrew_cask"
        case .appStore: "app_store"
        }
    }
}
