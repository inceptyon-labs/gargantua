import SwiftUI

extension CleanupMethod {
    var displayTitle: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete Permanently"
        }
    }

    var displayDetail: String {
        switch self {
        case .trash: "Reversible from macOS Trash."
        case .delete: "Irreversible. Files are removed immediately."
        }
    }

    var systemImage: String {
        switch self {
        case .trash: "trash"
        case .delete: "xmark.bin.fill"
        }
    }

    var actionTitle: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete Permanently"
        }
    }

    var progressTitle: String {
        switch self {
        case .trash: "Moving items to Trash..."
        case .delete: "Deleting items permanently..."
        }
    }

    var summaryActionText: String {
        switch self {
        case .trash: "moved to Trash"
        case .delete: "deleted permanently"
        }
    }

    var accentColor: Color {
        switch self {
        case .trash: GargantuaColors.safe
        case .delete: GargantuaColors.protected_
        }
    }
}

func cleanupTotalLineText(itemCount: Int, totalSize: Int64, method: CleanupMethod) -> String {
    let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
    let sizeText = AlertItem.formatBytes(totalSize)
    return "Clean \(countText) (\(sizeText)) - \(method.displayTitle)"
}
