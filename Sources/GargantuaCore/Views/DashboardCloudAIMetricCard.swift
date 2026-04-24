import SwiftUI

struct DashboardCloudAIMetricCard: View {
    let status: CloudAIStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("TIER 2 CLOUD")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink)

            Text(detail)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space4)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(tone)
                .frame(width: 28, height: 2)
                .padding(.horizontal, GargantuaSpacing.space4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private var title: String {
        guard let status else { return "Checking" }
        if status.isReady { return "Ready" }
        if status.isEnabled { return "Needs key" }
        return "Off"
    }

    private var detail: String {
        guard let status else {
            return "Tier 2 status loading."
        }

        let cost = "\(formatCents(status.spentCents)) / \(formatCents(status.monthlySpendCapCents))"
        let lastRun = status.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "never"
        return "Cost \(cost) · last run \(lastRun)"
    }

    private var tone: Color {
        guard let status else { return GargantuaColors.ink4 }
        if status.isReady { return GargantuaColors.safe }
        if status.isEnabled { return GargantuaColors.review }
        return GargantuaColors.ink4
    }

    private func formatCents(_ cents: Int) -> String {
        let value = Decimal(cents) / Decimal(100)
        return value.formatted(.currency(code: "USD"))
    }
}
