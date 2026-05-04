import AppKit
import SwiftUI

struct ScanRootsSettingsSection: View {
    let settings: PersistedSettings?
    let persistence: PersistenceController
    let onSettingsChanged: (PersistedSettings) -> Void

    @State private var newScanRoot = ""
    @State private var scanRootError: String?
    @State private var pendingRemoval: PendingScanRootRemoval?

    private struct PendingScanRootRemoval: Identifiable {
        let index: Int
        let path: String
        var id: Int { index }
    }

    var body: some View {
        SettingsSectionContainer(
            "Scan Roots",
            subtitle: "Where dev-purge looks for build artifacts. Empty list uses sensible defaults.",
            count: storedScanRoots.isEmpty ? nil : storedScanRoots.count
        ) {
            ScanRootsSummaryRow(
                count: storedScanRoots.count,
                isAutomatic: storedScanRoots.isEmpty,
                onReset: { persistScanRoots([]) }
            )

            divider

            ScanRootsList(
                roots: storedScanRoots,
                onMove: moveScanRoot,
                onRemove: requestRemoveScanRoot
            )

            divider

            ScanRootEntryRow(
                newScanRoot: $newScanRoot,
                onAdd: addTypedScanRoot,
                onChoose: chooseScanRoots
            )

            if let scanRootError {
                SettingsNoticeRow(
                    icon: "exclamationmark.triangle.fill",
                    message: scanRootError,
                    tone: .protected
                )
            }
        }
        .sheet(item: $pendingRemoval) { pending in
            DestructiveConfirmSheet(
                title: "Remove this scan root?",
                message: "Future scans will not look inside \(abbreviatedScanRootPath(pending.path)). You can re-add it any time.",
                confirmLabel: "Remove root",
                onCancel: { pendingRemoval = nil },
                onConfirm: {
                    let index = pending.index
                    pendingRemoval = nil
                    removeScanRoot(at: index)
                }
            )
        }
    }

    private var storedScanRoots: [String] {
        ScanRootSettings.normalizedStrings(from: settings?.scanRoots ?? [])
    }

    private var divider: some View {
        SettingsHairlineDivider()
    }

    private func requestRemoveScanRoot(at index: Int) {
        let roots = storedScanRoots
        guard roots.indices.contains(index) else { return }
        pendingRemoval = PendingScanRootRemoval(index: index, path: roots[index])
    }

    private func addTypedScanRoot() {
        let root = newScanRoot
        guard ScanRootSettings.isValid(root) else {
            scanRootError = "Enter an absolute path or ~/ path, excluding / and home."
            return
        }

        let updated = ScanRootSettings.normalizedStrings(from: storedScanRoots + [root])
        guard updated.count > storedScanRoots.count else {
            scanRootError = "That scan root is already listed."
            return
        }

        persistScanRoots(updated)
        newScanRoot = ""
    }

    private func removeScanRoot(at index: Int) {
        var roots = storedScanRoots
        guard roots.indices.contains(index) else { return }
        roots.remove(at: index)
        persistScanRoots(roots)
    }

    private func moveScanRoot(_ index: Int, _ direction: Int) {
        var roots = storedScanRoots
        let destination = index + direction
        guard roots.indices.contains(index), roots.indices.contains(destination) else { return }
        roots.swapAt(index, destination)
        persistScanRoots(roots)
    }

    private func chooseScanRoots() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true

        if panel.runModal() == .OK {
            appendScanRoots(panel.urls.map(\.standardizedFileURL.path))
        }
    }

    private func appendScanRoots(_ roots: [String]) {
        let updated = ScanRootSettings.normalizedStrings(from: storedScanRoots + roots)
        guard updated.count > storedScanRoots.count else {
            scanRootError = "Selected scan roots are already listed or invalid."
            return
        }
        persistScanRoots(updated)
    }

    private func persistScanRoots(_ roots: [String]) {
        do {
            let normalized = ScanRootSettings.normalizedStrings(from: roots)
            try persistence.updateSettings { settings in
                settings.scanRoots = normalized
            }
            onSettingsChanged(try persistence.fetchSettings())
            scanRootError = nil
        } catch {
            scanRootError = error.localizedDescription
        }
    }
}

private struct ScanRootsSummaryRow: View {
    let count: Int
    let isAutomatic: Bool
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "folder", size: 14)

            Text(isAutomatic ? "Automatic" : "Custom")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Text(isAutomatic ? "Auto" : "\(count)")
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)

            if !isAutomatic {
                GargantuaIconButton(
                    icon: "arrow.counterclockwise",
                    help: "Reset to default scan roots",
                    color: GargantuaColors.accent,
                    action: onReset
                )
            }
        }
        .scanRootRowStyle()
    }
}

private struct ScanRootsList: View {
    let roots: [String]
    let onMove: (Int, Int) -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        if roots.isEmpty {
            ScanRootDefaultsList()
        } else {
            ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                ScanRootRow(
                    root: root,
                    index: index,
                    count: roots.count,
                    onMove: onMove,
                    onRemove: onRemove
                )

                if index < roots.count - 1 {
                    scanRootDivider
                }
            }
        }
    }
}

private struct ScanRootDefaultsList: View {
    private let defaults = PathExpander.defaultScanRoots()

    var body: some View {
        if defaults.isEmpty {
            ScanRootStateRow(
                icon: "folder.badge.questionmark",
                title: "No default roots found",
                value: "Add one"
            )
        } else {
            ForEach(defaults, id: \.path) { root in
                ScanRootStateRow(
                    icon: "sparkle.magnifyingglass",
                    title: abbreviatedScanRootPath(root.path),
                    value: "Default"
                )

                if root.path != defaults.last?.path {
                    scanRootDivider
                }
            }
        }
    }
}

private struct ScanRootStateRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: icon, size: 14)

            Text(title)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink2)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(value)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .scanRootRowStyle()
    }
}

private struct ScanRootRow: View {
    let root: String
    let index: Int
    let count: Int
    let onMove: (Int, Int) -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.accent)
                .frame(width: 24, alignment: .center)

            Text(abbreviatedScanRootPath(root))
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            ScanRootRowControls(
                index: index,
                count: count,
                onMove: onMove,
                onRemove: onRemove
            )
        }
        .scanRootRowStyle()
    }
}

private struct ScanRootRowControls: View {
    let index: Int
    let count: Int
    let onMove: (Int, Int) -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            GargantuaIconButton(
                icon: "chevron.up",
                help: "Move scan root up",
                color: GargantuaColors.ink2,
                isDisabled: index == 0
            ) {
                onMove(index, -1)
            }

            GargantuaIconButton(
                icon: "chevron.down",
                help: "Move scan root down",
                color: GargantuaColors.ink2,
                isDisabled: index == count - 1
            ) {
                onMove(index, 1)
            }

            GargantuaIconButton(
                icon: "xmark",
                help: "Remove scan root",
                color: GargantuaColors.protected_
            ) {
                onRemove(index)
            }
        }
    }
}

private struct ScanRootEntryRow: View {
    @Binding var newScanRoot: String
    let onAdd: () -> Void
    let onChoose: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            TextField("Add project root path", text: $newScanRoot)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit(onAdd)

            GargantuaIconButton(
                icon: "plus",
                help: "Add scan root",
                color: GargantuaColors.accent,
                isDisabled: newScanRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: onAdd
            )

            GargantuaIconButton(
                icon: "folder.badge.plus",
                help: "Choose scan root from disk",
                color: GargantuaColors.accent,
                action: onChoose
            )
        }
        .scanRootRowStyle()
    }
}
