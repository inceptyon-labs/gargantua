import Foundation

/// Input payload for the MCP `list_app_updates` tool.
public struct MCPListAppUpdatesInput: Codable, Sendable {
    /// Include rows with no available update (up to date, ignored, skipped,
    /// failed, untracked). Default false: available updates only.
    public let includeAll: Bool?
    /// Exact bundle identifier of one app to inspect.
    public let bundleID: String?

    public init(includeAll: Bool? = nil, bundleID: String? = nil) {
        self.includeAll = includeAll
        self.bundleID = bundleID
    }

    private enum CodingKeys: String, CodingKey {
        case includeAll = "include_all"
        case bundleID = "bundle_id"
    }
}

/// One app row returned by `list_app_updates`.
public struct MCPAppUpdateSummary: Codable, Sendable {
    public let bundleID: String
    public let name: String
    public let installedVersion: String
    /// `available | link_only | updates_itself | up_to_date | ignored | skipped | failed | untracked`.
    public let status: String
    /// Newest version offered; nil unless an update is available.
    public let availableVersion: String?
    /// `catalog | sparkle | homebrew_cask | app_store`; nil without a candidate.
    public let source: String?
    /// Homebrew cask token that owns the install, when brew would update it.
    public let brewManagedToken: String?
    /// The candidate has a download URL (false for link-only and App Store).
    public let directDownload: Bool

    public init(
        bundleID: String,
        name: String,
        installedVersion: String,
        status: String,
        availableVersion: String?,
        source: String?,
        brewManagedToken: String?,
        directDownload: Bool
    ) {
        self.bundleID = bundleID
        self.name = name
        self.installedVersion = installedVersion
        self.status = status
        self.availableVersion = availableVersion
        self.source = source
        self.brewManagedToken = brewManagedToken
        self.directDownload = directDownload
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case installedVersion = "installed_version"
        case status
        case availableVersion = "available_version"
        case source
        case brewManagedToken = "brew_managed_token"
        case directDownload = "direct_download"
    }
}

/// Complete MCP `list_app_updates` response payload.
public struct MCPListAppUpdatesOutput: Codable, Sendable {
    public let items: [MCPAppUpdateSummary]
    /// Real count of rows matching the request; `items` is capped.
    public let totalItems: Int
    /// Apps with an update available among all apps checked.
    public let availableCount: Int

    public init(items: [MCPAppUpdateSummary], totalItems: Int, availableCount: Int) {
        self.items = items
        self.totalItems = totalItems
        self.availableCount = availableCount
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case totalItems = "total_items"
        case availableCount = "available_count"
    }
}
