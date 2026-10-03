import GargantuaLicensing
import SwiftUI

/// Small informational chip surfaced in the header trailing slot while the user
/// is mid-trial. Hidden once licensed; turns amber in the final 3 days as a
/// gentle nudge — not a nag.
public struct TrialStatusChip: View {
    private let model: LicenseStateModel
    private let onTap: (() -> Void)?

    @MainActor
    public init(model: LicenseStateModel? = nil, onTap: (() -> Void)? = nil) {
        self.model = model ?? .shared
        self.onTap = onTap
    }

    public var body: some View {
        Group {
            switch model.state {
            case .trial(let days):
                chip(label: trialLabel(days: days), tone: tone(for: days))
            case .expired:
                chip(label: "Trial · ended", tone: .protected)
            case .none, .licensed:
                EmptyView()
            }
        }
        .task { await model.refresh() }
    }

    private func trialLabel(days: Int) -> String {
        days == 1 ? "Trial · 1 day left" : "Trial · \(days) days left"
    }

    private enum Tone {
        case neutral, warning, protected
    }

    private func tone(for days: Int) -> Tone {
        days <= 3 ? .warning : .neutral
    }

    @ViewBuilder
    private func chip(label: String, tone: Tone) -> some View {
        let foreground: Color = {
            switch tone {
            case .neutral: GargantuaColors.ink2
            case .warning: GargantuaColors.review
            case .protected: GargantuaColors.protected_
            }
        }()
        let background: Color = {
            switch tone {
            case .neutral: GargantuaColors.surface3
            case .warning: GargantuaColors.reviewDim
            case .protected: GargantuaColors.protectedDim
            }
        }()

        let capsule = Text(label)
            .font(GargantuaFonts.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(background)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(foreground.opacity(0.25), lineWidth: 1)
            )

        // A plain label when there's nowhere to go, rather than a disabled
        // button promising to open settings.
        if let onTap {
            Button(action: onTap) { capsule }
                .buttonStyle(.plain)
                .help("Open License settings")
        } else {
            capsule
        }
    }
}
