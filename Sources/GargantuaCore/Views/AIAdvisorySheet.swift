import SwiftUI

/// Sheet that renders the state of an `AIAdvisoryController`. Attach via
/// `.sheet(item:)` on any scan view's enclosing container — the controller
/// drives identity and lifecycle, this view is pure presentation.
///
/// Functional stub: mirrors `AIExplanationSheet`'s shape but lists advisories
/// for the batch. Visual polish / custom layout is intentionally deferred
/// (per gargantua-7sge scope).
public struct AIAdvisorySheet: View {
    @ObservedObject var controller: AIAdvisoryController
    /// Called when the user taps "Open Settings" from the YAML-fallback
    /// footer. `MainContentView` uses this to switch sidebar to settings.
    public let onOpenSettings: (() -> Void)?

    /// Mirror of `controller.presentation` retained across the sheet's
    /// dismiss animation. The moment the user taps Close, `controller.dismiss`
    /// flips `presentation` to `nil`. A `Group { if let … }` body then
    /// evaluates to an empty view, and macOS shrinks the sheet content to
    /// its minimum (visible as a rounded-square "squircle" mid-animation)
    /// before the sheet actually leaves the screen. Caching the last
    /// non-nil presentation AND backing the sheet with a fixed-size
    /// background `Color` keeps the sheet holding its shape through the
    /// animation even if SwiftUI re-renders the body mid-tear-down.
    @State private var lastPresentation: AIAdvisoryPresentation?

    public init(
        controller: AIAdvisoryController,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ZStack {
            // Always-present background sized by the outer frame. Without
            // this, when the conditional content below collapses to empty
            // during dismissal, there's no sized view for the sheet host
            // to animate — it shrinks to a squircle before vanishing.
            GargantuaColors.surface1

            if let presentation = controller.presentation ?? lastPresentation {
                content(for: presentation)
            }
        }
        .frame(minWidth: 520, maxWidth: 640, minHeight: 320, maxHeight: 600)
        .onChange(of: controller.presentation) { _, new in
            if let new {
                lastPresentation = new
            }
            // When `new` is nil (controller dismissing), keep `lastPresentation`
            // so the fade-out animation has something meaningful to render.
        }
    }

    @ViewBuilder
    private func content(for presentation: AIAdvisoryPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(GargantuaColors.border)

            Group {
                switch presentation {
                case .loading:
                    loadingView
                case .loaded(let advisories):
                    loadedView(advisories)
                case .failed(let message):
                    failedView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().background(GargantuaColors.border)
            footer(for: presentation)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GargantuaColors.accent)
                Text("Review Advisories")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            Text("AI suggestions are advisory only — safety classifications come from YAML rules and are never changed.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            ProgressView()
                .controlSize(.small)
                .tint(GargantuaColors.accent)
            Text("Generating advisories…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func loadedView(_ advisories: [ScanResultAdvisory]) -> some View {
        if advisories.isEmpty {
            VStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(GargantuaColors.ink3)
                Text("No review-tier items to advise on.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                    ForEach(advisories, id: \.resultId) { advisory in
                        advisoryRow(advisory)
                    }
                }
                .padding(GargantuaSpacing.space4)
            }
        }
    }

    private func advisoryRow(_ advisory: ScanResultAdvisory) -> some View {
        let result = controller.result(for: advisory.resultId)
        return VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space2) {
                Text(result?.name ?? advisory.resultId)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                sourceBadge(advisory.source)
            }

            if let path = result?.path {
                Text(path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(advisory.rationale)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: GargantuaSpacing.space1) {
                Text("AI suggests:")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                suggestedSafetyBadge(advisory.suggestedSafety)
            }
        }
        .padding(GargantuaSpacing.space3)
        .background(GargantuaColors.surface2.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GargantuaColors.review)
                Text("Advisory failed")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.review)
            }
            Text(message)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space4)
    }

    // MARK: - Badges

    @ViewBuilder
    private func sourceBadge(_ source: ExplanationSource) -> some View {
        switch source {
        case .ai:
            badge(label: "AI", icon: "sparkles", color: GargantuaColors.accent)
        case .rule:
            badge(label: "YAML", icon: "doc.text.magnifyingglass", color: GargantuaColors.ink3)
        }
    }

    @ViewBuilder
    private func suggestedSafetyBadge(_ level: SafetyLevel) -> some View {
        switch level {
        case .safe:
            badge(label: "safe", icon: "circle.fill", color: GargantuaColors.safe)
        case .review:
            badge(label: "review", icon: "circle.fill", color: GargantuaColors.review)
        case .protected_:
            badge(label: "protected", icon: "circle.fill", color: GargantuaColors.protected_)
        }
    }

    private func badge(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(GargantuaFonts.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    // MARK: - Footer

    private func footer(for presentation: AIAdvisoryPresentation) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if case .loaded(let advisories) = presentation,
               advisories.contains(where: { $0.source == .rule }),
               !controller.isModelAvailable,
               onOpenSettings != nil {
                Button("Download Model") {
                    controller.dismiss()
                    onOpenSettings?()
                }
                .buttonStyle(AdvisoryAccentButtonStyle())
            }

            if case .failed = presentation {
                Button("Retry") { controller.retry() }
                    .buttonStyle(AdvisoryAccentButtonStyle())
            }

            Spacer()

            Button(presentation.closeLabel) {
                controller.dismiss()
            }
            .buttonStyle(AdvisorySecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }
}

private extension AIAdvisoryPresentation {
    var closeLabel: String {
        if case .loading = self { return "Cancel" }
        return "Close"
    }
}

// MARK: - Button styles

private struct AdvisoryAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GargantuaFonts.label)
            .foregroundStyle(GargantuaColors.accent)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.accent.opacity(configuration.isPressed ? 0.22 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }
}

private struct AdvisorySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GargantuaFonts.label)
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(GargantuaColors.surface3.opacity(configuration.isPressed ? 0.8 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }
}
