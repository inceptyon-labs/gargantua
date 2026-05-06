import SwiftUI

struct DashboardTriageEvidenceView: View {
    let alerts: [AlertItem]
    let hasRunTriage: Bool
    let scanProgress: ScanProgress
    let onNavigate: (AlertDestination) -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scanProgress.isScanning {
                progressContent
            } else if alerts.isEmpty {
                emptyContent
            } else {
                ForEach(alerts) { alert in
                    DashboardTriageEvidenceRow(alert: alert) {
                        onNavigate(alert.destination)
                    }

                    if alert.id != alerts.last?.id {
                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                            .padding(.leading, GargantuaSpacing.space4)
                    }
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

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.surface2)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.accent)
                        .frame(
                            width: geo.size.width * scanProgress.fractionCompleted,
                            height: 4
                        )
                }
            }
            .frame(height: 4)

            HStack(spacing: GargantuaSpacing.space2) {
                Text(scanProgress.currentCategory.map { "Scanning \($0)" } ?? "Scanning local cleanup rules")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()

                if scanProgress.itemsFound > 0 {
                    Text("\(scanProgress.itemsFound) items found")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
        .padding(GargantuaSpacing.space4)
    }

    private var emptyContent: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: hasRunTriage ? "checkmark.circle" : "list.bullet.clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hasRunTriage ? GargantuaColors.safe : GargantuaColors.accent)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text(hasRunTriage ? "No triage groups found" : "No triage evidence yet")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(hasRunTriage
                    ? "The lightweight local pass did not find safe or review-tier cleanup groups."
                    : "Run triage to populate evidence and rank the deeper cleanup tools.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            Button(action: onScan) {
                Text(hasRunTriage ? "Refresh Triage" : "Run Triage")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
        }
        .padding(GargantuaSpacing.space4)
    }
}

private struct DashboardTriageEvidenceRow: View {
    let alert: AlertItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(alert.categoryLabel.capitalized)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text("\(alert.detail) routed to \(destinationLabel)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                }

                Spacer()

                Text(AlertItem.formatBytes(alert.reclaimableSize))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink4)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var destinationLabel: String {
        switch alert.destination {
        case .deepClean: return "Deep Clean"
        case .devPurge: return "Dev Artifact Purge"
        case .diskExplorer: return "Disk Explorer"
        }
    }
}
