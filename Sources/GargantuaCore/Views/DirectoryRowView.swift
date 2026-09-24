import AppKit
import GargantuaLicensing
import SwiftUI

struct DirectoryRowView: View {
    let item: DirectoryItem
    let maxSize: Int64
    let isExpanded: Bool
    let onExpand: (() async -> Void)?
    let onDrillDown: () -> Void
    let onItemTrashed: (() -> Void)?
    let onLicenseBlocked: (BlockReason) -> Void
    var indentLevel: Int = 0

    @State private var isHovered = false
    @State private var isLoadingChildren = false
    @State private var pendingTrashDecision: DiskExplorerTrashDecision?
    @State private var trashError: String?
    @Environment(\.openURL) private var openURL

    private static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    private var sizeBarFraction: CGFloat {
        guard maxSize > 0, item.size > 0 else { return 0 }
        return CGFloat(item.size) / CGFloat(maxSize)
    }

    private var isFilesAggregate: Bool {
        item.isFilesAggregate
    }

    private var mountRootCaption: String {
        item.isNetworkVolume ? "Network volume — open to size" : "Separate volume — open to size"
    }

    var body: some View {
        Button {
            if item.isOthersAggregate {
                // Aggregate row is informational; matches treemap behavior.
            } else if item.isPermissionDenied {
                openURL(Self.fullDiskAccessURL)
            } else if !isFilesAggregate {
                onDrillDown()
            }
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                // Expand/collapse chevron (directories only — not aggregates,
                // not permission-denied).
                if !isFilesAggregate && !item.isPermissionDenied && !item.isOthersAggregate {
                    expandButton
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }

                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(iconTint)
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(nameTint)
                        .lineLimit(1)

                    if item.isPermissionDenied {
                        Text("Requires Full Disk Access")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    } else if item.isMountRoot {
                        Text(mountRootCaption)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                    }
                }

                Spacer()

                HStack(spacing: GargantuaSpacing.space3) {
                    if item.isPermissionDenied {
                        grantAccessAffordance
                    } else if item.isMountRoot {
                        Text("—")
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink4)
                            .frame(width: 70, alignment: .trailing)
                    } else if item.isSizing {
                        Color.clear.frame(width: 100, height: 6)
                        AccretionDiskView(activityRate: 18, size: 12, color: GargantuaColors.accretion)
                            .frame(width: 70, alignment: .trailing)
                    } else if item.isOthersAggregate {
                        sizeLabelView
                    } else {
                        sizeBar
                        sizeLabelView
                    }
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.leading, CGFloat(indentLevel) * GargantuaSpacing.space5)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if canRevealInFinder {
                Button("Reveal in Finder") { revealInFinder() }
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

    /// Aggregate rows render flat against `surface1` to read as informational;
    /// regular rows lift to `surface3` on hover, matching the treemap's
    /// hover-lift convention.
    private var rowBackground: Color {
        if item.isOthersAggregate { return GargantuaColors.surface1 }
        return isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2
    }

    private var nameTint: Color {
        if item.isPermissionDenied { return GargantuaColors.ink4 }
        if item.isOthersAggregate { return GargantuaColors.ink3 }
        return GargantuaColors.ink
    }

    /// Icon stays one tonal step dimmer than the name across all states.
    private var iconTint: Color {
        if item.isPermissionDenied { return GargantuaColors.ink4 }
        if item.isOthersAggregate { return GargantuaColors.ink4 }
        return GargantuaColors.ink2
    }

    private var canRevealInFinder: Bool {
        !item.isPermissionDenied
            && !item.isSizing
            && !item.isFilesAggregate
            && !item.isOthersAggregate
    }

    /// Menu visibility, from a lexical (no filesystem access) decision so it's
    /// cheap to compute on every body pass.
    private func canTrash(for decision: DiskExplorerTrashDecision) -> Bool {
        guard canRevealInFinder, onItemTrashed != nil, !item.isMountRoot else { return false }
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

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: item.path)]
        )
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

    private var expandButton: some View {
        Button {
            guard let onExpand else { return }
            Task {
                isLoadingChildren = true
                await onExpand()
                isLoadingChildren = false
            }
        } label: {
            Group {
                if isLoadingChildren {
                    AccretionDiskView(activityRate: 18, size: 12, color: GargantuaColors.accretion)
                } else {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }

    private var grantAccessAffordance: some View {
        // Pure label — the surrounding row Button already routes
        // permission-denied taps to the Full Disk Access settings pane.
        // Rendering this as another Button would nest tap targets and
        // produce different hit regions for the same action.
        HStack(spacing: GargantuaSpacing.space1) {
            Text("Grant Access")
                .font(GargantuaFonts.caption)
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(GargantuaColors.review)
    }

    private var sizeBar: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(GargantuaColors.accent.opacity(0.2))
                .frame(width: geo.size.width)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.accent)
                        .frame(width: max(2, geo.size.width * sizeBarFraction))
                }
        }
        .frame(width: 100, height: 6)
    }

    @ViewBuilder
    private var sizeLabelView: some View {
        if item.isPartial {
            formattedSizeLabel
                .help("Partial size — some items couldn't be read or sizing hit its time limit.")
        } else {
            formattedSizeLabel
        }
    }

    private var formattedSizeLabel: some View {
        Text(sizeLabel)
            .font(GargantuaFonts.monoData)
            .foregroundStyle(sizeLabelColor)
            .frame(width: 70, alignment: .trailing)
    }

    private var sizeLabel: String {
        guard !item.isPermissionDenied else { return "—" }
        let prefix = item.isPartial ? "~" : ""
        return "\(prefix)\(AlertItem.formatBytes(item.size))"
    }

    private var sizeLabelColor: Color {
        if item.isPermissionDenied { return GargantuaColors.ink4 }
        if item.isOthersAggregate { return GargantuaColors.ink3 }
        if item.isPartial { return GargantuaColors.ink2 }
        return GargantuaColors.ink
    }

    private var iconName: String {
        if item.isOthersAggregate { return "ellipsis.circle" }
        if isFilesAggregate { return "doc" }
        if item.isPermissionDenied { return "lock.fill" }
        if item.isMountRoot {
            return item.isNetworkVolume ? "externaldrive.connected.to.line.below" : "externaldrive"
        }
        return "folder.fill"
    }
}
