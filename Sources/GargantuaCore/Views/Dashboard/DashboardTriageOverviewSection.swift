import SwiftUI

struct DashboardTriageOverviewSection: View {
    let diskUsage: Double
    let reclaimableFraction: Double
    let freeDiskGB: Int
    let reclaimableSummary: String
    let triageStatusPill: String
    let roadmapHeadline: String
    let roadmapDetail: String
    let gaugeHelpText: String

    var body: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space5) {
            HealthGaugeView(
                diskUsage: diskUsage,
                reclaimableFraction: reclaimableFraction
            )
            .help(gaugeHelpText)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                Text("CLEANUP ROADMAP")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink4)

                Text(roadmapHeadline)
                    .font(GargantuaFonts.title)
                    .foregroundStyle(GargantuaColors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roadmapDetail)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(maxWidth: 760, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: GargantuaSpacing.space2) {
                    DashboardEvidencePill(text: "\(freeDiskGB) GB free", monospaced: true)
                    if reclaimableFraction > 0 {
                        DashboardEvidencePill(text: reclaimableSummary, monospaced: true)
                    }
                    DashboardEvidencePill(text: triageStatusPill)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(GargantuaSpacing.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }
}
