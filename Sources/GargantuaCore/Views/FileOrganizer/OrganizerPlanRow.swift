import SwiftUI

/// One expandable row inside `OrganizerStagedPreviewView`. Collapsed
/// state shows plan name, file count, total bytes, and the first line
/// of AI reasoning. Expanded state reveals full reasoning + the per-file
/// move list.
struct OrganizerPlanRow: View {
    let plan: OrganizationPlan
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Rectangle()
                    .fill(GargantuaColors.borderSoft)
                    .frame(height: 1)
                expandedDetail
            }
        }
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(GargantuaColors.accent)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text(plan.name)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                        Text("·")
                            .foregroundStyle(GargantuaColors.ink4)
                        Text("\(plan.moves.count) file\(plan.moves.count == 1 ? "" : "s")")
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                    Text(plan.reasoning)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                        .lineLimit(isExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(GargantuaSpacing.space3)
        }
        .buttonStyle(.plain)
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            ForEach(plan.moves) { move in
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(GargantuaColors.ink4)
                    Text(move.sourceURL.lastPathComponent)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(plan.name)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
        .padding(GargantuaSpacing.space3)
    }
}
