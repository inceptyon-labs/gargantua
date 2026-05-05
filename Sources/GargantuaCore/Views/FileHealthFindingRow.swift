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
    let groupContext: FileHealthCategoryTab.GroupContext?
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onExplain: ((ScanResult) -> Void)?

    @FocusState private var isFocused: Bool
    @State private var isHovered: Bool = false
    @Environment(\.activeAIEngineKind) private var activeAIEngineKind

    init(
        result: ScanResult,
        groupContext: FileHealthCategoryTab.GroupContext? = nil,
        isSelected: Bool,
        onToggleSelection: @escaping () -> Void,
        onExplain: ((ScanResult) -> Void)? = nil
    ) {
        self.result = result
        self.groupContext = groupContext
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
        self.onExplain = onExplain
    }

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

                if let group = groupContext {
                    // Surface similarity/duplicate cluster membership so a
                    // user reviewing a duplicate doesn't read it as a
                    // standalone finding.
                    Text("Group \(group.index) · \(group.count) cop\(group.count == 1 ? "y" : "ies")")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .accessibilityLabel("Group \(group.index), \(group.count) total copies")
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

            // Mirror DenseScanItemRow's Explain affordance: visible at rest
            // in ink3, brightens to accent on row hover with an inline
            // "Why?" label so the action names itself.
            if let onExplain {
                Button {
                    onExplain(result)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: explainGlyph)
                            .font(.system(size: 14))
                        if isHovered {
                            Text("Why?")
                                .font(GargantuaFonts.caption)
                        }
                    }
                    .foregroundStyle(isHovered ? GargantuaColors.accent : GargantuaColors.ink3)
                }
                .buttonStyle(.plain)
                .help("Why was this flagged?")
                .accessibilityLabel("Why was this flagged?")
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isSelected ? result.safety.tintBackground : Color.clear)
        .onHover { isHovered = $0 }
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
                    Label("Why was this flagged?", systemImage: explainGlyph)
                }
            }
        }
    }

    private var explainGlyph: String {
        switch activeAIEngineKind {
        case .mlx: return "sparkles"
        case .template: return "questionmark.circle.fill"
        }
    }
}
