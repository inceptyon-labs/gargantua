import SwiftUI

/// Dashboard signpost for apps with an update available, the count the App
/// Updates sidebar badge shows. Deep-links into App Updates; it installs
/// nothing.
struct DashboardAppUpdatesSignpost: View {
    let count: Int
    /// Empty when the names aren't known; the card then shows only the count.
    let appNames: [String]
    let onOpen: () -> Void

    private var title: String {
        AppReleaseUpdatesText.title(count: count)
    }

    private var detail: String {
        appNames.isEmpty ? "Review and install them in App Updates." : AppReleaseUpdatesText.appList(appNames)
    }

    private var accessibilityText: String {
        appNames.isEmpty ? "\(title). \(detail) Opens App Updates." : "\(title): \(detail). Opens App Updates."
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(GargantuaColors.accent)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    Text(title)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    Text(detail)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: GargantuaSpacing.space3)

                HStack(spacing: GargantuaSpacing.space1) {
                    Text("Open")
                        .font(GargantuaFonts.label)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(GargantuaColors.accent)
            }
            .padding(GargantuaSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
        .buttonStyle(.plain)
        .help("Open App Updates to review and install them")
        .accessibilityLabel(accessibilityText)
    }
}
