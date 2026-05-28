import SwiftUI

/// A dismissible banner warning that a permission is missing.
///
/// Styled with `--review-dim` background and `--review` text per the design
/// system. Includes a direct link to the relevant System Settings pane.
/// Dismiss state is held in `@State` so the banner reappears on next launch.
public struct PermissionBannerView: View {
    let message: String
    let settingsURL: URL

    @State private var isDismissed = false

    public init(message: String, settingsURL: URL) {
        self.message = message
        self.settingsURL = settingsURL
    }

    @Environment(\.openURL) private var openURL

    public var body: some View {
        if !isDismissed {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(GargantuaColors.review)

                Text(message)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.review)

                Spacer()

                Button {
                    openURL(settingsURL)
                } label: {
                    Text("Open Settings")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .underline()
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(GargantuaColors.reviewDim)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.review.opacity(0.25), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Convenience Initializers

extension PermissionBannerView {
    /// Banner for missing Full Disk Access, shown on scan screens.
    public static var fullDiskAccess: PermissionBannerView {
        PermissionBannerView(
            message: "Some system paths are inaccessible. "
                + "Open Full Disk Access settings, click \"+\", and add Gargantua.",
            settingsURL: URL(
                string: "x-apple.systempreferences:"
                    + "com.apple.preference.security?Privacy_AllFiles"
            )!
        )
    }
}
