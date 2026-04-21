import SwiftUI

extension CleanupMethod {
    var displayTitle: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete Permanently"
        case .toolNative: "Run Tool Cleanup"
        }
    }

    var displayDetail: String {
        switch self {
        case .trash: "Reversible from macOS Trash."
        case .delete: "Irreversible. Files are removed immediately."
        case .toolNative: "Runs the tool's own cleanup command."
        }
    }

    var systemImage: String {
        switch self {
        case .trash: "trash"
        case .delete: "xmark.bin.fill"
        case .toolNative: "terminal"
        }
    }

    var actionTitle: String {
        switch self {
        case .trash: "Move to Trash"
        case .delete: "Delete Permanently"
        case .toolNative: "Run Cleanup"
        }
    }

    var progressTitle: String {
        switch self {
        case .trash: "Moving items to Trash..."
        case .delete: "Deleting items permanently..."
        case .toolNative: "Running tool cleanup..."
        }
    }

    var summaryActionText: String {
        switch self {
        case .trash: "moved to Trash"
        case .delete: "deleted permanently"
        case .toolNative: "cleaned by tool"
        }
    }

    var accentColor: Color {
        switch self {
        case .trash: GargantuaColors.safe
        case .delete: GargantuaColors.protected_
        case .toolNative: GargantuaColors.accent
        }
    }
}

func cleanupTotalLineText(itemCount: Int, totalSize: Int64, method: CleanupMethod) -> String {
    let countText = itemCount == 1 ? "1 item" : "\(itemCount) items"
    let sizeText = AlertItem.formatBytes(totalSize)
    return "Clean \(countText) (\(sizeText)) - \(method.displayTitle)"
}
