import Foundation

/// Input payload for the MCP `list_background_items` tool.
public struct MCPListBackgroundItemsInput: Codable, Sendable {
    /// Item to inspect, matched against the internal launchd Label OR the
    /// plist filename stem (they can legitimately differ). When present, the
    /// handler returns every match instead of the full scan — the same label
    /// can also exist in both the user and system domains.
    public let label: String?

    /// Creates a list-background-items input.
    public init(label: String? = nil) {
        self.label = label
    }
}

/// Best-effort launchd runtime facts for one background item, mirroring
/// `LaunchdRuntimeState`. Display metadata only — never classification input.
public struct MCPBackgroundItemRuntime: Codable, Sendable {
    public let isLoaded: Bool?
    public let pid: Int?
    public let lastExitStatus: Int?
    public let disabledOverride: Bool?

    /// Creates a background item runtime summary.
    public init(
        isLoaded: Bool?,
        pid: Int?,
        lastExitStatus: Int?,
        disabledOverride: Bool?
    ) {
        self.isLoaded = isLoaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
        self.disabledOverride = disabledOverride
    }
}

/// One background item row returned by `list_background_items`.
public struct MCPBackgroundItemSummary: Codable, Sendable {
    public let label: String
    public let displayName: String
    /// `user_launch_agent | system_launch_agent | launch_daemon | startup_item | login_item`.
    public let source: String
    /// `SafetyLevel.rawValue`.
    public let safety: String
    /// `BackgroundItemReason` raw values, sorted for deterministic output —
    /// the source `Set` has no stable iteration order.
    public let reasons: [String]
    public let explanation: String
    public let plistPath: String?
    public let executablePath: String?
    public let isOrphaned: Bool
    public let runtime: MCPBackgroundItemRuntime?

    /// Creates a background item summary row.
    public init(
        label: String,
        displayName: String,
        source: String,
        safety: String,
        reasons: [String],
        explanation: String,
        plistPath: String?,
        executablePath: String?,
        isOrphaned: Bool,
        runtime: MCPBackgroundItemRuntime?
    ) {
        self.label = label
        self.displayName = displayName
        self.source = source
        self.safety = safety
        self.reasons = reasons
        self.explanation = explanation
        self.plistPath = plistPath
        self.executablePath = executablePath
        self.isOrphaned = isOrphaned
        self.runtime = runtime
    }
}

/// Complete MCP `list_background_items` response payload.
public struct MCPListBackgroundItemsOutput: Codable, Sendable {
    public let items: [MCPBackgroundItemSummary]
    /// Real matching-item count. `items` is capped for the wire
    /// (`MCPListBackgroundItemsToolHandler.maxItemsInWireOutput`), so a
    /// trimmed list stays distinguishable from a complete one.
    public let totalItems: Int
    public let loginItemsNeedPrivileges: Bool
    public let unparseableCount: Int

    /// Creates a list-background-items output payload.
    public init(
        items: [MCPBackgroundItemSummary],
        totalItems: Int,
        loginItemsNeedPrivileges: Bool,
        unparseableCount: Int
    ) {
        self.items = items
        self.totalItems = totalItems
        self.loginItemsNeedPrivileges = loginItemsNeedPrivileges
        self.unparseableCount = unparseableCount
    }
}
