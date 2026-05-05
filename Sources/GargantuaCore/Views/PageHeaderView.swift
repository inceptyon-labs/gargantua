import SwiftUI

/// How a header's subtitle line is rendered. The component picks one
/// based on whether the copy is *voice* (scene-setting brand line on a
/// feature-root entry screen) or *status* (a count, descriptive technical
/// blurb, or other quiet metadata).
public enum HeaderSubtitleStyle {
    /// `caption` 11pt + `ink3`. Quiet, doesn't compete with the title.
    /// Default for descriptive or numeric subtitles.
    case status
    /// `body.italic` 13pt + `ink2`. Brand voice. Used on feature-root
    /// entry screens where the subtitle is scene-setting copy.
    case voice
}

/// Top-of-page header bar shared across destination views.
///
/// Leading-aligned title with optional subtitle, optional trailing action slot,
/// followed by a 1pt `border` rule that separates the header from page content.
/// Pads `space4` horizontally and vertically to match the canonical pattern
/// established in DiskExplorerIdleView, DeepCleanView, AIModelsView, and
/// DevArtifactScanView.
public struct PageHeaderView<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let subtitleStyle: HeaderSubtitleStyle
    private let trailing: () -> Trailing

    public init(
        title: String,
        subtitle: String? = nil,
        subtitleStyle: HeaderSubtitleStyle = .status,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleStyle = subtitleStyle
        self.trailing = trailing
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(GargantuaFonts.heading)
                        .foregroundStyle(GargantuaColors.ink)
                    if let subtitle {
                        styledSubtitle(subtitle)
                    }
                }

                Spacer()

                trailing()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func styledSubtitle(_ text: String) -> some View {
        switch subtitleStyle {
        case .status:
            Text(text)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(2)
        case .voice:
            Text(text)
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .lineLimit(2)
        }
    }
}

extension PageHeaderView where Trailing == EmptyView {
    public init(
        title: String,
        subtitle: String? = nil,
        subtitleStyle: HeaderSubtitleStyle = .status
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleStyle: subtitleStyle,
            trailing: { EmptyView() }
        )
    }
}
