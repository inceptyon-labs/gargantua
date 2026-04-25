import AppKit
import SwiftUI

/// Scan-bucket row wrapper that handles protected rows and item context actions.
struct ScanResultRowView: View {
    let item: ScanResult
    let isSelected: Bool
    let isFocused: Bool
    let onToggleSelection: () -> Void
    let onExplain: ((ScanResult) -> Void)?
    let onAddToWhitelist: ((ScanResult) -> Void)?
    let onViewRule: ((ScanResult) -> Void)?

    var body: some View {
        Group {
            if item.safety == .protected_ {
                protectedRow
            } else if isSelected {
                selectableRow(isSelected: true)
            } else {
                selectableRow(isSelected: false)
            }
        }
        .contextMenu { scanItemContextMenu }
    }

    private func selectableRow(isSelected: Bool) -> some View {
        DenseScanItemRow(
            item: item,
            isSelected: isSelected,
            isFocused: isFocused,
            onToggleSelection: onToggleSelection,
            onExplain: onExplain.map { handler in { handler(item) } }
        )
    }

    /// Protected items: shown but dimmed, locked indicator, no checkbox.
    private var protectedRow: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ConfidenceOrbit(confidence: item.confidence, safety: item.safety)

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

                    if !item.explanation.isEmpty {
                        Text(item.explanation)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink4)
                            .lineLimit(1)
                    }
                }

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            onAddToWhitelist?(item)
        } label: {
            Label("Add to Whitelist", systemImage: "shield.slash")
        }

        Button {
            onViewRule?(item)
        } label: {
            Label("View Rule", systemImage: "doc.text.magnifyingglass")
        }
    }
}
