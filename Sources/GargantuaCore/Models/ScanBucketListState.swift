import Foundation
import Observation

/// The results list's view state (grouping, collapsed groups, search), kept by
/// the owning session so leaving the screen and coming back doesn't reset it.
/// The grouping mode is also remembered across launches, per screen.
@Observable @MainActor
public final class ScanBucketListState {
    public var groupingMode: ScanGroupingMode {
        didSet {
            if let groupingDefaultsKey {
                defaults.set(groupingMode.rawValue, forKey: groupingDefaultsKey)
            }
        }
    }

    /// Groups start expanded; this holds the ones the user collapsed.
    public var collapsedGroupIDs: Set<String> = []
    public var naturalLanguageQuery = ""
    public var activeFilter: ScanFilterSet?
    public var filterStatus: String?
    public var showsRefineControls = false
    /// Selected items the current filter hides. Only visible items can be
    /// cleaned while filtering; these come back when the filter changes or
    /// clears.
    public var selectionHiddenByFilter: Set<String> = []

    @ObservationIgnored private let groupingDefaultsKey: String?
    @ObservationIgnored private let defaults: UserDefaults

    public init(
        groupingDefaultsKey: String? = nil,
        defaultGrouping: ScanGroupingMode = .safety,
        defaults: UserDefaults = .standard
    ) {
        self.groupingDefaultsKey = groupingDefaultsKey
        self.defaults = defaults
        self.groupingMode = groupingDefaultsKey
            .flatMap { defaults.string(forKey: $0) }
            .flatMap(ScanGroupingMode.init(rawValue:)) ?? defaultGrouping
    }

    /// A new scan's results start unfiltered with every group open; the
    /// grouping mode carries over.
    public func resetForNewResults() {
        collapsedGroupIDs = []
        naturalLanguageQuery = ""
        activeFilter = nil
        filterStatus = nil
        showsRefineControls = false
        selectionHiddenByFilter = []
    }
}
