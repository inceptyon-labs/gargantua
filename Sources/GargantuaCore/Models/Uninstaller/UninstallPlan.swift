import Foundation

/// A full uninstall proposal for a single app.
///
/// Aggregates the app's bundle (`appBundle`) with every remnant the
/// scanner discovered. The plan is pure data — execution happens in a
/// separate layer that takes this plan, runs it through the Trust Layer
/// confirmation flow, and sends items to the Trash.
public struct UninstallPlan: Codable, Sendable, Identifiable {
    /// Plan identifier — generated when the plan is produced.
    public let id: UUID

    /// The app being uninstalled.
    public let app: AppInfo

    /// The `.app` bundle itself, modelled as a remnant so the UI and the
    /// cleanup engine can treat it uniformly. `nil` for "remnants only"
    /// cleanups of apps already removed.
    public let appBundle: RemnantItem?

    /// Every non-bundle remnant the scanner found, in discovery order.
    public let remnants: [RemnantItem]

    /// When the plan was generated.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        app: AppInfo,
        appBundle: RemnantItem? = nil,
        remnants: [RemnantItem] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.app = app
        self.appBundle = appBundle
        self.remnants = remnants
        self.createdAt = createdAt
    }

    /// Every item the plan proposes to remove, bundle first.
    public var allItems: [RemnantItem] {
        var items: [RemnantItem] = []
        if let appBundle { items.append(appBundle) }
        items.append(contentsOf: remnants)
        return items
    }

    /// Total bytes across bundle + remnants.
    public var totalBytes: Int64 {
        allItems.reduce(0) { $0 + $1.size }
    }

    /// Remnants grouped by category, preserving the discovery order within
    /// each group.
    public var remnantsByCategory: [RemnantCategory: [RemnantItem]] {
        Dictionary(grouping: remnants, by: \.category)
    }

    /// Items the user can actually select for cleanup — excludes
    /// `protected` remnants that require an explicit override.
    public var actionableItems: [RemnantItem] {
        allItems.filter { $0.safety.isActionable }
    }
}
