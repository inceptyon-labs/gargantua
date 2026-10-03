import SwiftUI

/// One expandable row inside `OrganizerStagedPreviewView`. Collapsed
/// state shows plan name, file count, total bytes, and the first line
/// of AI reasoning. Expanded state reveals full reasoning + the per-file
/// move list. The plan's checkbox and each file's decide what Apply moves.
struct OrganizerPlanRow: View {
    let plan: OrganizationPlan
    let isMoveIncluded: (UUID) -> Bool
    let onSetMoves: ([UUID], Bool) -> Void
    @Binding var isExpanded: Bool

    private enum CheckState { case none, partial, all }

    private var includedCount: Int {
        plan.moves.filter { isMoveIncluded($0.id) }.count
    }

    private var planCheckState: CheckState {
        switch includedCount {
        case 0: .none
        case plan.moves.count: .all
        default: .partial
        }
    }

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

    // The checkbox sits beside the expand button, not inside its label, so
    // a click on it can't also toggle expansion.
    private var header: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            checkbox(planCheckState) {
                onSetMoves(plan.moves.map(\.id), planCheckState != .all)
            }
            .help(planCheckState == .all ? "Leave this folder out" : "Include every file in this folder")
            .padding(.top, GargantuaSpacing.space3)

            expandButton
        }
        .padding(.leading, GargantuaSpacing.space3)
    }

    private var expandButton: some View {
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
                        Text(fileCountLabel)
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
            .padding([.vertical, .trailing], GargantuaSpacing.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            ForEach(plan.moves) { move in
                let included = isMoveIncluded(move.id)
                HStack(spacing: GargantuaSpacing.space2) {
                    checkbox(included ? .all : .none) {
                        onSetMoves([move.id], !included)
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(GargantuaColors.ink4)
                    Text(move.sourceURL.lastPathComponent)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(included ? GargantuaColors.ink2 : GargantuaColors.ink4)
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

    private var fileCountLabel: String {
        let total = plan.moves.count
        let files = "\(total) file\(total == 1 ? "" : "s")"
        return includedCount == total ? files : "\(includedCount) of \(files)"
    }

    private func checkbox(_ state: CheckState, action: @escaping () -> Void) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(state == .none ? Color.clear : GargantuaColors.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(state == .none ? GargantuaColors.borderEm : GargantuaColors.accent, lineWidth: 1.5)
                )
                .frame(width: 14, height: 14)
            if state != .none {
                Image(systemName: state == .all ? "checkmark" : "minus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state == .all ? "Included" : state == .partial ? "Partly included" : "Excluded")
    }
}
