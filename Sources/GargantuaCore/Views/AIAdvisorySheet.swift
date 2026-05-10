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

    @Environment(\.aiEngineNeedsFirstWarmup) private var needsFirstWarmup
    @Environment(\.openAIModelSettings) private var openAIModelSettings
    @Environment(\.preferredAIEngineKind) private var preferredAIEngineKind

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
                Text(controller.currentRequestIsTriage ? "Suspicious Triage" : "Review Advisories")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            Text(headerSubtitle)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    private var headerSubtitle: String {
        if controller.currentRequestIsTriage {
            return "AI reviews only the highest-signal candidates. This is triage, not malware detection."
        }
        return "Suggestions are advisory only — safety classifications come from YAML rules and are never changed."
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

            if needsFirstWarmup {
                Text("Compiling shaders for first use…")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
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
                Text(controller.currentRequestIsTriage ? "No suspicious candidates to advise on." : "No review-tier items to advise on.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                    if preferredAIEngineKind == .template,
                       advisories.allSatisfy({ $0.source == .template }) {
                        enableAIFooterNote
                    }

                    ForEach(advisories, id: \.resultId) { advisory in
                        advisoryRow(advisory)
                    }
                }
                .padding(GargantuaSpacing.space4)
            }
        }
    }

    private var enableAIFooterNote: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.ink3)
            Text("These are rule-based. Enable local AI in Settings → AI Model for generated advisories.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space3)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
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
                Text(suggestedClassificationLabel(for: advisory.source))
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

    // MARK: - Footer

    private func footer(for presentation: AIAdvisoryPresentation) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if case .loaded(let advisories) = presentation {
                footerCTA(for: advisories)
            }

            if case .failed = presentation {
                Button("Retry") { controller.retry() }
                    .buttonStyle(AIModalButtonStyle(tone: .accent))
                    .focusable(false)
            }

            Spacer()

            Button(presentation.closeLabel) {
                controller.dismiss()
            }
            .buttonStyle(AIModalButtonStyle(tone: .secondary))
            .focusable(false)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    /// Footer CTA differs by what the advisory batch contains AND by toggle:
    /// - `.template` entries + AI toggle off → "Enable AI".
    /// - `.template` entries + AI toggle on (fallback) OR `.rule` fallback +
    ///   no model on disk → "Download Model".
    /// - all `.ai` (or `.rule` with model present, i.e. engine errors) → no
    ///   CTA needed.
    @ViewBuilder
    private func footerCTA(for advisories: [ScanResultAdvisory]) -> some View {
        let hasTemplate = advisories.contains(where: { $0.source == .template })
        let hasRule = advisories.contains(where: { $0.source == .rule })

        if hasTemplate, preferredAIEngineKind == .template {
            if let openSettings = onOpenSettings ?? openAIModelSettings {
                Button("Enable AI") {
                    controller.dismiss()
                    openSettings()
                }
                .buttonStyle(AIModalButtonStyle(tone: .accent))
                .focusable(false)
                .help("Open Settings → AI Model")
            }
        } else if hasTemplate || hasRule,
                  !controller.isModelAvailable,
                  onOpenSettings != nil {
            Button("Download Model") {
                controller.dismiss()
                onOpenSettings?()
            }
            .buttonStyle(AIModalButtonStyle(tone: .accent))
            .focusable(false)
        }
    }
}

private extension AIAdvisoryPresentation {
    var closeLabel: String {
        if case .loading = self { return "Cancel" }
        return "Close"
    }
}
