import SwiftUI

/// Dense list of actionable alerts for the dashboard, with optional Quick Scan button.
///
/// Each row shows reclaimable space by category with a click-through
/// to the relevant cleanup screen. When `scanProgress` is provided and
/// a scan is active, the alert list is replaced by an inline progress view.
public struct AlertListView: View {
    private let alerts: [AlertItem]
    private let onNavigate: (AlertDestination) -> Void
    private let scanProgress: ScanProgress?
    private let onScan: (() -> Void)?

    public init(
        alerts: [AlertItem],
        onNavigate: @escaping (AlertDestination) -> Void,
        scanProgress: ScanProgress? = nil,
        onScan: (() -> Void)? = nil
    ) {
        self.alerts = alerts
        self.onNavigate = onNavigate
        self.scanProgress = scanProgress
        self.onScan = onScan
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Quick Scan header (shown when onScan is provided)
            if onScan != nil {
                scanHeader

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            // Content: progress during scan, alerts otherwise
            if scanProgress?.isScanning == true {
                scanProgressView
            } else if alerts.isEmpty {
                emptyState
            } else {
                ForEach(alerts) { alert in
                    AlertRowView(alert: alert) {
                        onNavigate(alert.destination)
                    }
                    if alert.id != alerts.last?.id {
                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                    }
                }
            }
        }
    }

    // MARK: - Quick Scan Header

    private var scanHeader: some View {
        HStack {
            Text("Alerts")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            Spacer()

            Button(action: { onScan?() }) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quick Scan")
                        .font(GargantuaFonts.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space1)
                .background(GargantuaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(scanProgress?.isScanning == true)
            .opacity(scanProgress?.isScanning == true ? 0.5 : 1)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    // MARK: - Inline Progress

    private var scanProgressView: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.surface2)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(GargantuaColors.accent)
                        .frame(
                            width: geo.size.width * (scanProgress?.fractionCompleted ?? 0),
                            height: 4
                        )
                        .animation(.easeInOut(duration: 0.2), value: scanProgress?.fractionCompleted)
                }
            }
            .frame(height: 4)

            // Status text
            HStack {
                if let category = scanProgress?.currentCategory {
                    Text("Scanning \(category)…")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                } else {
                    Text("Scanning…")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                }

                Spacer()

                if let found = scanProgress?.itemsFound, found > 0 {
                    Text("\(found) items found")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space4)
    }

    // MARK: - Empty State

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
