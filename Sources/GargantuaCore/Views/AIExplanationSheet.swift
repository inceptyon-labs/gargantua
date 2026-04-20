import SwiftUI

/// Sheet that renders the state of an `AIExplanationController`. Attach via
/// `.sheet(item:)` on any scan view — the controller drives the identity and
/// lifecycle, this view is pure presentation.
public struct AIExplanationSheet: View {
    @ObservedObject var controller: AIExplanationController
    /// Called when the user taps "Open Settings" from the YAML-fallback footer.
    /// `MainContentView` uses this to switch sidebar selection to settings.
    public let onOpenSettings: (() -> Void)?

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
            }
            .padding(GargantuaSpacing.space4)
        }
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
            if case .loaded(_, let explanation) = presentation,
               explanation.source == .rule,
               !controller.isModelAvailable,
               onOpenSettings != nil {
                Button("Download Model") {
                    controller.dismiss()
                    onOpenSettings?()
                }
                .buttonStyle(AccentButtonStyle())
            }

            if case .failed = presentation {
                Button("Retry") { controller.retry() }
                    .buttonStyle(AccentButtonStyle())
            }

            Spacer()

            Button(presentation.closeLabel) {
                controller.dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }
}

private extension AIExplanationPresentation {
    var closeLabel: String {
        if case .loading = self { return "Cancel" }
        return "Close"
    }
}

// MARK: - Button styles

private struct AccentButtonStyle: ButtonStyle {
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

private struct SecondaryButtonStyle: ButtonStyle {
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
