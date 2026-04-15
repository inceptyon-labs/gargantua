import SwiftUI

/// Dense list of actionable alerts for the dashboard.
///
/// Each row shows reclaimable space by category with a click-through
/// to the relevant cleanup screen. Follows the design system's
/// dense list pattern with --ink/--ink-2/--font-mono hierarchy.
public struct AlertListView: View {
    private let alerts: [AlertItem]
    private let onNavigate: (AlertDestination) -> Void

    public init(
        alerts: [AlertItem],
        onNavigate: @escaping (AlertDestination) -> Void
    ) {
        self.alerts = alerts
        self.onNavigate = onNavigate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if alerts.isEmpty {
                emptyState
            } else {
                ForEach(alerts) { alert in
                    AlertRowView(alert: alert) {
                        onNavigate(alert.destination)
                    }
                    if alert.id != alerts.last?.id {
                        Divider()
                            .background(GargantuaColors.borderSoft)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No reclaimable items found")
            .font(GargantuaFonts.body)
            .foregroundStyle(GargantuaColors.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, GargantuaSpacing.space4)
            .padding(.horizontal, GargantuaSpacing.space3)
    }
}

// MARK: - Alert Row

/// A single alert row: headline text + monospace size + chevron.
struct AlertRowView: View {
    let alert: AlertItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(alert.headline)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text(alert.detail)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }

                Spacer()

                Text(AlertItem.formatBytes(alert.reclaimableSize))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink4)
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
