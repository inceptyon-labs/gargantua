import SwiftUI

extension SmartUninstallerView {
    // MARK: - Phase Animation Plumbing

    /// Stable key for the phase bucket. `.scanning(app)` and
    /// `.scanning(otherApp)` share a key so SwiftUI doesn't crossfade when
    /// only the associated value changes; only real phase transitions do.
    var phaseKey: String {
        switch viewModel.phase {
        case .idle: "idle"
        case .loadingApps: "loadingApps"
        case .pickingApp: "pickingApp"
        case .scanning: "scanning"
        case .reviewingPlan: "reviewingPlan"
        case .executing: "executing"
        case .summary: "summary"
        case .batchScanning: "batchScanning"
        case .batchExecuting: "batchExecuting"
        case .batchSummary: "batchSummary"
        case .failed: "failed"
        }
    }

    /// Transition between phase screens. Incoming view fades + rises up from
    /// 12pt below with a scale bump from 0.92; outgoing fades and drops away.
    /// The substantial motion + offset make the executing → summary swap feel
    /// like a deliberate transition against the dark background, where the
    /// two screens are so visually different that a subtle opacity fade reads
    /// as a hard cut. Reduce-motion collapses to a cut so users with the OS
    /// preference set don't get the animation every time they click.
    var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92))
                .combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -16))
        )
    }
}
