import SwiftUI

struct DashboardRoadmapView: View {
    let steps: [DashboardRoadmapStep]
    let isScanning: Bool
    let onAction: (DashboardRoadmapAction) -> Void

    var body: some View {
        DashboardSection(title: "NEXT ACTIONS") {
            VStack(spacing: 0) {
                ForEach(steps) { step in
                    DashboardRoadmapRow(
                        step: step,
                        isScanning: isScanning,
                        onAction: { onAction(step.action) }
                    )

                    if step.id != steps.last?.id {
                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }
}

private struct DashboardRoadmapRow: View {
    let step: DashboardRoadmapStep
    let isScanning: Bool
    let onAction: () -> Void

    private var actionIsDisabled: Bool {
        isScanning && step.action == .scan
    }

    private var isPrimary: Bool { step.rank == 1 }

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Text("\(step.rank)")
                .font(GargantuaFonts.monoData.weight(.semibold))
                .foregroundStyle(isPrimary ? GargantuaColors.ink : GargantuaColors.ink2)
                .frame(width: 28, height: 28)
                .background(isPrimary ? GargantuaColors.accent : GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

            Image(systemName: step.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isPrimary ? GargantuaColors.accent : GargantuaColors.ink2)
                .frame(width: 24, height: 28, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
                    Text(step.title)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text(step.status.uppercased())
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                }

                Text(step.detail)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        ForEach(step.evidence, id: \.self) { evidence in
                            DashboardEvidencePill(text: evidence)
                        }
                    }

                    VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                        ForEach(step.evidence, id: \.self) { evidence in
                            DashboardEvidencePill(text: evidence)
                        }
                    }
                }
            }

            Spacer(minLength: GargantuaSpacing.space4)

            Button(action: onAction) {
                Label(actionIsDisabled ? "Scanning" : step.actionLabel, systemImage: buttonSystemImage)
                    .font(GargantuaFonts.label)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(GargantuaColors.ink)
                    .frame(width: 120)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(step.action == .scan ? Color.clear : GargantuaColors.borderEm, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(actionIsDisabled)
            .opacity(actionIsDisabled ? 0.65 : 1)
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var buttonBackground: Color {
        if step.action == .scan {
            return actionIsDisabled ? GargantuaColors.ink4 : GargantuaColors.accent
        }
        return GargantuaColors.surface3
    }

    private var buttonSystemImage: String {
        if actionIsDisabled { return "hourglass" }
        switch step.action {
        case .scan: return "list.bullet.clipboard"
        case .navigate: return "arrow.right"
        }
    }
}
