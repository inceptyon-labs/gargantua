import Foundation

enum DiskExplorerContentMode: Equatable {
    case scanning
    case empty
    case treemap
    case list
    case dominant(DirectoryItem)
    /// User selected Focus mode but no folder in this directory dominates
    /// enough for the hero-card layout to be meaningful. Renders an
    /// explanation and a way back to Treemap or List.
    case focusUnavailable

    static func == (lhs: DiskExplorerContentMode, rhs: DiskExplorerContentMode) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning),
             (.empty, .empty),
             (.treemap, .treemap),
             (.list, .list),
             (.focusUnavailable, .focusUnavailable):
            return true
        case let (.dominant(l), .dominant(r)):
            return l.id == r.id
        default:
            return false
        }
    }
}
