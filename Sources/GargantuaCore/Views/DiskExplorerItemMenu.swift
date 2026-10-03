import AppKit
import GargantuaLicensing
import SwiftUI

/// The context menu every Disk Explorer item shares (list rows, treemap tiles
/// and the Focus card): Reveal in Finder, Copy Path and Move to Trash, with
/// the trash confirmation and error alerts.
struct DiskExplorerItemMenu: ViewModifier {
    let item: DirectoryItem
    /// `nil` hides Move to Trash.
    let onItemTrashed: (() -> Void)?
    let onLicenseBlocked: (BlockReason) -> Void

    @State private var pendingTrashDecision: DiskExplorerTrashDecision?
    @State private var trashError: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if hasRealPath {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.path, forType: .string)
                    }
                }
                let menuDecision = DiskExplorerTrashPolicy.lexicalDecision(path: item.path)
                if canTrash(for: menuDecision) {
                    Divider()
                    Button(trashMenuLabel(for: menuDecision), role: .destructive) { beginTrash() }
                }
            }
            .alert(
                trashConfirmTitle,
                isPresented: Binding(
                    get: { pendingTrashDecision != nil },
                    set: { if !$0 { pendingTrashDecision = nil } }
                )
            ) {
                Button(trashConfirmButtonLabel, role: .destructive) { moveToTrash() }
                Button("Cancel", role: .cancel) { pendingTrashDecision = nil }
            } message: {
                trashConfirmMessage
            }
            .alert(
                "Could not move to Trash",
                isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })
            ) {
                Button("OK", role: .cancel) { trashError = nil }
            } message: {
                Text(trashError ?? "")
            }
    }

    /// The aggregates have no path of their own, and a row still sizing or
    /// behind Full Disk Access isn't ready to act on.
    private var hasRealPath: Bool {
        !item.isPermissionDenied
            && !item.isSizing
            && !item.isFilesAggregate
            && !item.isOthersAggregate
    }

    /// Menu visibility, from a lexical (no filesystem access) decision so it's
    /// cheap to compute on every body pass.
    private func canTrash(for decision: DiskExplorerTrashDecision) -> Bool {
        guard hasRealPath, onItemTrashed != nil, !item.isMountRoot else { return false }
        if case .blocked = decision { return false }
        return true
    }

    private func trashMenuLabel(for decision: DiskExplorerTrashDecision) -> String {
        if case .outsideHome = decision { return "Move to Trash…" }
        return "Move to Trash"
    }

    /// Runs the full (filesystem-backed) decision once, on tap: blocked stops
    /// with an error, otherwise the confirmation alert opens.
    private func beginTrash() {
        let decision = DiskExplorerTrashPolicy.decision(
            path: item.path, protectedRoots: DiskExplorerTrashPolicy.menuProtectedRoots
        )
        if case .blocked(let reason) = decision {
            trashError = reason
            return
        }
        pendingTrashDecision = decision
    }

    private var trashConfirmTitle: String {
        if case .outsideHome = pendingTrashDecision { return "Move to Trash outside Home?" }
        return "Move to Trash?"
    }

    private var trashConfirmButtonLabel: String {
        if case .outsideHome = pendingTrashDecision { return "Move to Trash Anyway" }
        return "Move to Trash"
    }

    private var trashConfirmMessage: Text {
        if case .outsideHome = pendingTrashDecision {
            return Text(
                "\"\(item.name)\" (\(AlertItem.formatBytes(item.size))) at \(item.path) will be moved to your Trash. " +
                    "It's outside your Home folder — apps, Homebrew, or system software that use it may stop working. " +
                    "Finder's Put Back won't be available for it."
            )
        }
        return Text("\"\(item.name)\" (\(AlertItem.formatBytes(item.size))) will be moved to the Trash.")
    }

    private func moveToTrash() {
        Task { @MainActor in
            switch await LicenseGate.shared.authorize(.diskExplorer) {
            case .failure(let reason):
                onLicenseBlocked(reason)
                return
            case .success:
                break
            }
            // Report the failure rather than discarding it. Without this the
            // row simply stays put after a refresh, which is indistinguishable
            // from the delete never having been requested.
            DiskExplorerTrashPolicy.recycle(path: item.path) { error in
                if let error {
                    trashError = error.localizedDescription
                } else {
                    onItemTrashed?()
                }
            }
        }
    }
}
