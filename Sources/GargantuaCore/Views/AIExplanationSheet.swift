import SwiftUI

/// Sheet that renders the state of an `AIExplanationController`. Attach via
/// `.sheet(item:)` on any scan view — the controller drives the identity and
/// lifecycle, this view is pure presentation.
public struct AIExplanationSheet: View {
    @ObservedObject var controller: AIExplanationController
    /// Called when the user taps "Open Settings" from the YAML-fallback footer.
    /// `MainContentView` uses this to switch sidebar selection to settings.
    public let onOpenSettings: (() -> Void)?

    @Environment(\.aiEngineNeedsFirstWarmup) private var needsFirstWarmup
    @Environment(\.openAIModelSettings) private var openAIModelSettings
    @Environment(\.preferredAIEngineKind) private var preferredAIEngineKind

    /// Mirror of `controller.presentation` retained across the sheet's
    /// dismiss animation. Without this (and the `ZStack`/background pattern
    /// below), `controller.dismiss` flips `presentation` to `nil`, the body
    /// evaluates to empty, and macOS shrinks the sheet content to a
    /// rounded-square "squircle" mid-animation before the sheet actually
    /// leaves the screen.
    @State private var lastPresentation: AIExplanationPresentation?

    public init(
        controller: AIExplanationController,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.controller = controller
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ZStack {
            // Always-present background sized by the outer frame so the
            // sheet keeps its shape through the dismiss animation even when
            // the conditional content below has gone empty.
            GargantuaColors.surface1

            if let presentation = controller.presentation ?? lastPresentation {
                content(for: presentation)
            }
        }
        .frame(minWidth: 480, maxWidth: 560, minHeight: 280, maxHeight: 500)
        .onChange(of: controller.presentation) { _, new in
            if let new {
                lastPresentation = new
            }
        }
    }

    @ViewBuilder
    private func content(for presentation: AIExplanationPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(for: presentation.result)
            Divider().background(GargantuaColors.border)

            Group {
                switch presentation {
                case .loading:
                    loadingView
                case .loaded(_, let explanation):
                    loadedView(explanation)
                case .failed(_, let message):
                    failedView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().background(GargantuaColors.border)
            footer(for: presentation)
        }
    }

    // MARK: - Header

    private func header(for result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GargantuaColors.accent)
                Text("Explain")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            Text(result.name)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)
            Text(result.path)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
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
            Text("Generating explanation…")
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
    private func loadedView(_ explanation: AIExplanation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                sourceBadge(explanation.source)
                Text(explanation.text)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if explanation.source == .template, preferredAIEngineKind == .template {
                    enableAIFooterNote
                }
            }
            .padding(GargantuaSpacing.space4)
        }
    }

    private var enableAIFooterNote: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.ink3)
            Text("This is rule-based. Enable local AI in Settings → AI Model for generated explanations.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space3)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GargantuaColors.review)
                Text("Explanation failed")
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

    // MARK: - Source badge

    @ViewBuilder
    private func sourceBadge(_ source: ExplanationSource) -> some View {
        switch source {
        case .ai:
            badge(
                label: "AI generated",
                icon: "sparkles",
                color: GargantuaColors.accent
            )
        case .template:
            badge(
                label: "Rule-based · enable local AI for generated text",
                icon: "doc.text",
                color: GargantuaColors.ink3
            )
        case .rule:
            badge(
                label: "From YAML rule · AI model unavailable",
                icon: "doc.text.magnifyingglass",
                color: GargantuaColors.ink3
            )
        }
    }

    private func badge(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
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

    private func footer(for presentation: AIExplanationPresentation) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if case .loaded(_, let explanation) = presentation {
                footerCTA(for: explanation)
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

    /// Footer CTA differs by source AND by the user's toggle:
    /// - `.template` + AI toggle off → "Enable AI" (flip the toggle).
    /// - `.template` + AI toggle on (model missing/corrupt fallback) →
    ///   "Download Model" — the user already wants AI, the engine just
    ///   couldn't run.
    /// - `.rule` (engine error / no-model fallback) → "Download Model".
    /// - `.ai` → no CTA needed.
    @ViewBuilder
    private func footerCTA(for explanation: AIExplanation) -> some View {
        switch explanation.source {
        case .ai:
            EmptyView()
        case .template:
            if preferredAIEngineKind == .template {
                if let openSettings = onOpenSettings ?? openAIModelSettings {
                    Button("Enable AI") {
                        controller.dismiss()
                        openSettings()
                    }
                    .buttonStyle(AIModalButtonStyle(tone: .accent))
                    .focusable(false)
                    .help("Open Settings → AI Model")
                }
            } else if !controller.isModelAvailable, onOpenSettings != nil {
                Button("Download Model") {
                    controller.dismiss()
                    onOpenSettings?()
                }
                .buttonStyle(AIModalButtonStyle(tone: .accent))
                .focusable(false)
            }
        case .rule:
            if !controller.isModelAvailable, onOpenSettings != nil {
                Button("Download Model") {
                    controller.dismiss()
                    onOpenSettings?()
                }
                .buttonStyle(AIModalButtonStyle(tone: .accent))
                .focusable(false)
            }
        }
    }
}

private extension AIExplanationPresentation {
    var closeLabel: String {
        if case .loading = self { return "Cancel" }
        return "Close"
    }
}
