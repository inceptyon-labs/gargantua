import AppKit
import SwiftUI

/// One row inside a ``FileHealthView`` category tab.
///
/// Renders a safety-tinted checkbox (mirroring ``DenseScanItemRow`` so Deep
/// Clean and File Health share the same selection affordance), the finding's
/// name/path/explanation, and size. Selection is driven by a caller-supplied
/// binding to the scan session state owned by ``FileHealthContainerView``.
struct FileHealthFindingRow: View {
    let result: ScanResult
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onExplain: ((ScanResult) -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            // Checkbox mirrors DenseScanItemRow — 16×16 rounded rect, safety-
            // tinted fill when selected.
            ZStack {
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(
                        isSelected ? result.safety.tintColor : GargantuaColors.borderEm,
                        lineWidth: 1.5
                    )
                    .frame(width: 16, height: 16)
                    .background(isSelected ? result.safety.tintColor : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(isSelected ? "Deselect \(result.name)" : "Select \(result.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)

                Text(result.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !result.explanation.isEmpty {
                    Text(result.explanation)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                }
            }

            Spacer()

            if result.confidence > 0 {
                Text("\(result.confidence)%")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
                    .accessibilityLabel("\(result.confidence) percent confidence")
            }

            if result.size > 0 {
                Text(AlertItem.formatBytes(result.size))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isSelected ? result.safety.tintBackground : Color.clear)
        .overlay(
            // Focus ring uses borderFocus per design system. Visible only
            // while the row is keyboard-focused; the safety-tint background
            // already conveys selection.
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(isFocused ? GargantuaColors.borderFocus : Color.clear, lineWidth: 2)
                .padding(.horizontal, 2)
        )
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onTapGesture(perform: onToggleSelection)
        .onKeyPress(.space) {
            onToggleSelection()
            return .handled
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isSelected ? "Deselect" : "Select", onToggleSelection)
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(result.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            if let onExplain {
                Divider()
                Button {
                    onExplain(result)
                } label: {
                    Label("Explain", systemImage: "questionmark.circle")
                }
            }
        }
    }
}
