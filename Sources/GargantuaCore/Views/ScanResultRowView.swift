import AppKit
import SwiftUI

/// Scan-bucket row wrapper that handles protected rows and item context actions.
struct ScanResultRowView: View {
    let item: ScanResult
    let isSelected: Bool
    let isFocused: Bool
    /// Set by `ScanBucketListView.groupSection` to dedupe identical-explanation
    /// rows in the same group: only the first occurrence shows the prose.
    let showExplanation: Bool
    /// Non-nil when the item is view-only (protected root or non-allowlisted
    /// system path): the row renders locked, like `protected` safety, and the
    /// reason is shown. `protected` safety items lock regardless of this.
    let lockReason: String?
    /// Non-nil when a running app holds this item open. The row renders locked
    /// with a "Quit <app>" affordance; quitting unblocks and selects it.
    let blockedApp: BlockedApp?
    let onQuitBlockingApp: (() -> Void)?
    let onToggleSelection: () -> Void
    let onExplain: ((ScanResult) -> Void)?
    let onAddToExclusions: ((ScanResult) -> Void)?
    let onViewRule: ((ScanResult) -> Void)?

    init(
        item: ScanResult,
        isSelected: Bool,
        isFocused: Bool,
        showExplanation: Bool = true,
        lockReason: String? = nil,
        blockedApp: BlockedApp? = nil,
        onQuitBlockingApp: (() -> Void)? = nil,
        onToggleSelection: @escaping () -> Void,
        onExplain: ((ScanResult) -> Void)?,
        onAddToExclusions: ((ScanResult) -> Void)?,
        onViewRule: ((ScanResult) -> Void)?
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.showExplanation = showExplanation
        self.lockReason = lockReason
        self.blockedApp = blockedApp
        self.onQuitBlockingApp = onQuitBlockingApp
        self.onToggleSelection = onToggleSelection
        self.onExplain = onExplain
        self.onAddToExclusions = onAddToExclusions
        self.onViewRule = onViewRule
    }

    private var isLocked: Bool {
        item.safety == .protected_ || lockReason != nil || blockedApp != nil
    }

    var body: some View {
        Group {
            // One branch for both checkbox states, so toggling updates the row
            // instead of tearing it down and building a new one.
            if isLocked {
                protectedRow
            } else {
                selectableRow(isSelected: isSelected)
            }
        }
        .contextMenu { scanItemContextMenu }
    }

    private func selectableRow(isSelected: Bool) -> some View {
        DenseScanItemRow(
            item: item,
            isSelected: isSelected,
            isFocused: isFocused,
            showExplanation: showExplanation,
            onToggleSelection: onToggleSelection,
            onExplain: onExplain.map { handler in { handler(item) } }
        )
    }

    /// Protected items: shown but dimmed, locked indicator, no checkbox. The
    /// confidence orbit is dropped here — the lock already conveys the row's
    /// state and confidence is moot when the row can't be acted on.
    private var protectedRow: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Text(item.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)

                    if showExplanation, !item.explanation.isEmpty {
                        Text(item.explanation)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink4)
                            .lineLimit(1)
                    }
                }

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let blockedApp {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text("\(blockedApp.name) is running")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink4)
                        if let onQuitBlockingApp {
                            Button(action: onQuitBlockingApp) {
                                Text("Quit \(blockedApp.name)")
                                    .font(GargantuaFonts.caption)
                                    .foregroundStyle(GargantuaColors.accent)
                            }
                            .buttonStyle(.plain)
                            .help("Quit \(blockedApp.name) and include this item in the cleanup")
                        }
                    }
                } else if let lockReason {
                    Text("View only · \(lockReason)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(GargantuaColors.protected_.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderFocus, lineWidth: 2)
                .padding(1)
                .opacity(isFocused ? 1 : 0)
        )
    }

    @ViewBuilder
    private var scanItemContextMenu: some View {
        Button {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            onAddToExclusions?(item)
        } label: {
            Label("Add to Exclusions", systemImage: "shield.slash")
        }

        Button {
            onViewRule?(item)
        } label: {
            Label("View Rule", systemImage: "doc.text.magnifyingglass")
        }
    }
}
