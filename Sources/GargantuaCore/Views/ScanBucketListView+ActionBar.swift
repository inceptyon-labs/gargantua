import SwiftUI

extension ScanBucketListView {
    var actionBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                if selectedIDs.isEmpty {
                    Text("No items selected")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink2)
                    Text("Select safe items to build a cleanup plan.")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                } else {
                    Text("\(selectedIDs.count) items selected")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                    Text("\(AlertItem.formatBytes(reclaimableBytes)) ready for confirmation")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }

            Spacer()

            if !selectedIDs.isEmpty {
                Button {
                    selectedIDs.removeAll()
                } label: {
                    Text("Clear Selection")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                                .fill(GargantuaColors.surface3)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                                .stroke(GargantuaColors.borderEm, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Button(action: triggerClean) {
                Text("Review Cleanup")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(
                        selectedIDs.isEmpty
                            ? GargantuaColors.accent.opacity(0.4)
                            : GargantuaColors.accent
                    )
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }
}
