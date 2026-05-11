import Foundation
import SwiftUI

extension DeveloperToolPanel {
    func previewBody(_ preview: DeveloperToolPreview) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            commandRow(preview.commandPreview)

            let operations = DeveloperToolsView.operations(for: preview)
            if !operations.isEmpty {
                operationList(operations, preview: preview)
            }

            if preview.items.isEmpty {
                Text("Nothing to clean up.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink3)
            } else {
                previewDisclosure(preview)
            }
        }
    }

    @ViewBuilder
    func previewDisclosure(_ preview: DeveloperToolPreview) -> some View {
        let count = preview.items.count
        let suffix: String = {
            if preview.hasKnownReclaimableBytes {
                return ", \(Self.formatBytes(preview.reclaimableBytes))"
            }
            return ""
        }()
        // Custom expander instead of `DisclosureGroup` because the system
        // chevron on the void-dark background renders as near-invisible
        // dark gray. We draw the chevron explicitly in `ink2` so the user
        // can find the disclose affordance.
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: isPreviewExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink2)
                        .frame(width: 12, alignment: .center)
                    Text("Show what would be removed (\(count) item\(count == 1 ? "" : "s")\(suffix))")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(isPreviewExpanded ? "Hide" : "Show") what would be removed, \(count) items"
            )
            .accessibilityAddTraits(.isButton)

            if isPreviewExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.items) { item in
                        previewRow(item)
                        if item.id != preview.items.last?.id {
                            Rectangle()
                                .fill(GargantuaColors.borderSoft)
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .fill(GargantuaColors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.borderSoft, lineWidth: 1)
                )
            }
        }
    }

    func commandRow(_ command: [String]) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "terminal")
                .foregroundStyle(GargantuaColors.ink4)
            Text(command.joined(separator: " "))
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(GargantuaColors.surface3)
        )
    }

    func previewRow(_ item: DeveloperToolPreviewItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(item.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: GargantuaSpacing.space3)
            if let bytes = item.reclaimableBytes {
                Text(Self.formatBytes(bytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            } else {
                Text("—")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
    }
}
