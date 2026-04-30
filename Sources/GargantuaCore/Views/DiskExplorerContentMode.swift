import Foundation

enum DiskExplorerContentMode: Equatable {
    case scanning
    case empty
    case treemap
    case list
    case dominant(DirectoryItem)

    static func == (lhs: DiskExplorerContentMode, rhs: DiskExplorerContentMode) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning),
             (.empty, .empty),
             (.treemap, .treemap),
             (.list, .list):
            return true
        case let (.dominant(l), .dominant(r)):
            return l.id == r.id
        default:
            return false
        }
    }
}
