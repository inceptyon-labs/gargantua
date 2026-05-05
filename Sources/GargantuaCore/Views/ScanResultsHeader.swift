import SwiftUI

/// Shared chrome for the top of every scan-results screen.
///
/// Layout: `[Back]  leading-aligned title (+optional subtitle)            [Refresh] [Rescan]`,
/// followed by a 1-pt divider. Each trailing action is opt-in — pass `nil` to
/// hide it. Designed so Deep Clean, File Health, Dev Purge, Duplicate Finder,
/// and the Smart Uninstaller plan review all share one navigation pattern.
/// Title alignment matches the leading-aligned `PageHeaderView` used on
/// feature-root entry screens.
///
/// Semantics:
///   - **Back** — leave the results phase, return to the start/idle screen.
///   - **Refresh** — prune the existing list (drop items already deleted off-disk).
///   - **Rescan** — discard the current results and run the scan from scratch.
public struct ScanResultsHeader: View {
    public let title: String
    public let subtitle: String?
    public let onBack: (() -> Void)?
    public let onRefresh: (() -> Void)?
    public let onRescan: (() -> Void)?
    public let isBusy: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        onBack: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        onRescan: (() -> Void)? = nil,
        isBusy: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.onRefresh = onRefresh
        self.onRescan = onRescan
        self.isBusy = isBusy
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                if onBack != nil {
                    leadingSlot
                }

                titleStack

                Spacer()

                trailingSlot
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let onBack {
            Button(action: onBack) {
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(GargantuaFonts.label)
                }
                .foregroundStyle(GargantuaColors.accent)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            if let onRefresh {
                actionButton(label: "Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    .accessibilityLabel("Refresh list")
            }
            if let onRescan {
                actionButton(label: "Rescan", systemImage: "arrow.triangle.2.circlepath", action: onRescan)
                    .accessibilityLabel("Rescan from scratch")
            }
        }
    }

    private func actionButton(
        label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }
}
