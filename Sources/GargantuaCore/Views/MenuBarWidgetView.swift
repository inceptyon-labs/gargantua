import SwiftUI

public struct MenuBarStatusLabel: View {
    let snapshot: MenuBarStatusSnapshot

    public init(snapshot: MenuBarStatusSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        Image(systemName: snapshot.pendingAlertCount > 0 ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(snapshot.pendingAlertCount > 0 ? GargantuaColors.accent : .primary)
            .accessibilityLabel(snapshot.accessibilitySummary)
    }
}

public struct MenuBarWidgetView: View {
    @ObservedObject private var model: MenuBarStatusModel
    private let onOpenMainWindow: () -> Void

    public init(model: MenuBarStatusModel, onOpenMainWindow: @escaping () -> Void) {
        self.model = model
        self.onOpenMainWindow = onOpenMainWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            header

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                metricRow(icon: "externaldrive", label: "Reclaimable", value: model.snapshot.reclaimableDisplay)
                metricRow(icon: "bell", label: "Alerts", value: model.snapshot.alertsDisplay)
                metricRow(icon: "calendar", label: "Last Scan", value: model.snapshot.lastScanDisplay)
            }

            if let error = model.snapshot.errorMessage {
                HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)
                        .frame(width: 16, alignment: .center)

                    Text(error)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Menu bar error, \(error)")
            }

            HStack(spacing: GargantuaSpacing.space2) {
                menuActionButton("Open", systemImage: "arrow.up.forward.app") {
                    onOpenMainWindow()
                }
                .accessibilityLabel("Open Gargantua main window")

                menuActionButton("Quick Scan", systemImage: "magnifyingglass") {
                    Task { await model.runQuickScan() }
                }
                .disabled(model.snapshot.isScanning)
                .accessibilityLabel(model.snapshot.isScanning ? "Quick scan running" : "Run quick scan")

                menuActionButton("Snooze", systemImage: "moon.zzz") {
                    model.snoozeAlerts()
                }
                .disabled(!model.snapshot.canSnoozeAlerts)
                .accessibilityLabel("Snooze menu bar alerts")
            }
        }
        .padding(GargantuaSpacing.space4)
        .frame(width: 300, alignment: .leading)
        .background(GargantuaColors.surface2)
        .task {
            await model.refresh()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.snapshot.accessibilitySummary)
    }

    private var header: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(GargantuaColors.surface3)
                    .frame(width: 32, height: 32)

                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(GargantuaColors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Gargantua")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(model.snapshot.statusDisplay)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            if model.snapshot.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Quick scan running")
            }
        }
    }

    private var statusColor: Color {
        if model.snapshot.isScanning { return GargantuaColors.accent }
        if model.snapshot.errorMessage != nil { return GargantuaColors.review }
        if model.snapshot.pendingAlertCount > 0 { return GargantuaColors.accent }
        return GargantuaColors.safe
    }

    private func metricRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 18, alignment: .center)

            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)

            Spacer(minLength: GargantuaSpacing.space3)

            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    private func menuActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(GargantuaFonts.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, GargantuaSpacing.space2)
                .padding(.vertical, GargantuaSpacing.space2)
        }
        .buttonStyle(MenuBarActionButtonStyle())
    }
}

private struct MenuBarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GargantuaColors.ink)
            .background(configuration.isPressed ? GargantuaColors.surface3 : GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
