import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Single source of truth for the Agent Run "when to use this" copy. Both the
/// inline disclaimer above the preset picker and the `?` help sheet read from
/// this enum so the user sees identical framing in both places — and any copy
/// edit lands once.
///
/// The five example prompts are taken verbatim from the empirical test in
/// `gargantua-ryfq` (docs/scans/agent-vs-deep-scan-2026-04-30.md). They're the
/// queries that produced strong differentiation versus Deep Scan, so showing
/// them as examples is showing users prompts that have actually worked.
public enum ClaudeCodeAgentHelpContent {

    // MARK: Inline disclaimer

    public static let disclaimerLeadIn = "Agent Run is for situational questions"
    public static let disclaimerLeadInDetail = "pre-upgrade triage, orphan-cache hunting, version cleanup, criterion filtering (\u{2018}haven\u{2019}t used in 6 months\u{2019})."

    public static let disclaimerFallback = "For routine cleanup, run Deep Scan instead"
    public static let disclaimerFallbackDetail = "it\u{2019}s faster and produces the same result for the common case."

    // MARK: When to use Agent Run — example prompts

    public struct ExamplePrompt: Identifiable, Hashable {
        public let id: String
        public let useCase: String
        /// Compact topic phrase (≤24 chars) used when the prompt is rendered as
        /// a tap-to-fill chip under a preset. Distinct from `useCase`, which
        /// can be longer phrasing for the help-sheet listing.
        public let chipLabel: String
        public let prompt: String
    }

    public static let examplePrompts: [ExamplePrompt] = [
        ExamplePrompt(
            id: "pre-event-triage",
            useCase: "Pre-event triage",
            chipLabel: "Pre-upgrade triage",
            prompt: "I\u{2019}m doing a macOS upgrade tomorrow. What should I clean up first to free space and reduce migration risk?"
        ),
        ExamplePrompt(
            id: "orphan-cache-hunting",
            useCase: "Orphan / dead-app cache hunting",
            chipLabel: "Orphan caches",
            prompt: "Show me caches that are safe to delete because the apps that wrote them aren\u{2019}t installed anymore."
        ),
        ExamplePrompt(
            id: "version-cleanup",
            useCase: "Version cleanup",
            chipLabel: "Adobe version cleanup",
            prompt: "I have multiple versions of [Adobe X / Xcode / Node / etc.] installed. Recommend keeping just the latest stable release."
        ),
        ExamplePrompt(
            id: "criterion-filtering",
            useCase: "Criterion filtering",
            chipLabel: "Criterion filtering",
            prompt: "Find [Adobe / Steam / dev] apps and assets I haven\u{2019}t touched in 6+ months. Don\u{2019}t recommend things I\u{2019}m actively using."
        ),
        ExamplePrompt(
            id: "project-archaeology",
            useCase: "Project archaeology",
            chipLabel: "Stale dev projects",
            prompt: "What is the biggest potential cleanup in my ~/Development folder? Are there any project repositories I haven\u{2019}t opened in 6+ months that I could archive?"
        )
    ]

    // MARK: Per-preset chip mapping

    /// Maps each preset to the example-prompt IDs surfaced as chips beneath
    /// its picker. Edit this map in one place to change which prompts appear
    /// where — the chip labels and prompt bodies still come from
    /// `examplePrompts`, so there are no duplicated copy strings.
    ///
    /// Multiple presets reference the same prompt where the question fits
    /// either flow (e.g. orphan-cache-hunting and criterion-filtering both
    /// answer "what's safe to remove" and "what haven't I used"). With the
    /// vertical layout giving each preset a full-width chip row, we list
    /// 3-4 chips per preset to give users more starting points.
    public static let chipsByTemplate: [ClaudeCodeAgentPromptTemplate: [String]] = [
        .investigateSpace: [
            "pre-event-triage",
            "orphan-cache-hunting",
            "criterion-filtering",
            "version-cleanup",
        ],
        .projectArchaeology: [
            "project-archaeology",
            "criterion-filtering",
            "orphan-cache-hunting",
        ],
        .customCleanupScript: [
            "version-cleanup",
            "criterion-filtering",
            "orphan-cache-hunting",
            "pre-event-triage",
        ],
    ]

    /// Resolved chip prompts for a preset. Returns the matching
    /// `ExamplePrompt`s in the order specified by `chipsByTemplate`. IDs that
    /// don't resolve are silently dropped (kept defensive — the test suite
    /// pins both halves of the mapping so this is never expected at runtime).
    public static func chips(for template: ClaudeCodeAgentPromptTemplate) -> [ExamplePrompt] {
        let ids = chipsByTemplate[template] ?? []
        let lookup = Dictionary(uniqueKeysWithValues: examplePrompts.map { ($0.id, $0) })
        return ids.compactMap { lookup[$0] }
    }

    // MARK: When to use Deep Scan instead

    public static let whenToUseDeepScan: [String] = [
        "Just clean the obvious safe stuff (Deep Scan + Clean All is faster).",
        "\u{201C}What\u{2019}s taking the most space?\u{201D} (Deep Scan sorted by size answers this in 5 seconds).",
        "Routine weekly cleanup (Deep Scan with the developer profile)."
    ]
}

// MARK: - Help sheet view

/// Sheet rendered when the user taps the `?` button next to the Agent Run
/// title. Layout follows the design tokens (void background, surface cards,
/// ink hierarchy) so the sheet feels like the rest of the app rather than a
/// stock modal.
public struct ClaudeCodeAgentHelpView: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space5) {
                    agentSection
                    deepScanSection
                }
                .padding(GargantuaSpacing.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GargantuaColors.void_)
        }
        .frame(width: 560, height: 620)
        .background(GargantuaColors.void_)
    }

    private var header: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(GargantuaColors.accent)

            Text("When to use Agent Run")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space4)
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text("USE AGENT RUN WHEN\u{2026}")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(spacing: GargantuaSpacing.space2) {
                ForEach(ClaudeCodeAgentHelpContent.examplePrompts) { example in
                    ExamplePromptRow(example: example)
                }
            }
        }
    }

    private var deepScanSection: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Text("USE DEEP SCAN WHEN\u{2026}")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                ForEach(ClaudeCodeAgentHelpContent.whenToUseDeepScan, id: \.self) { line in
                    HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                        Text("\u{2022}")
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink3)
                        Text(line)
                            .font(GargantuaFonts.body)
                            .foregroundStyle(GargantuaColors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(GargantuaSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }
}

private struct ExamplePromptRow: View {
    let example: ClaudeCodeAgentHelpContent.ExamplePrompt
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text(example.useCase)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(didCopy ? "Copied" : "Copy")
                            .font(GargantuaFonts.caption)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Copy this example prompt to the clipboard")
            }

            Text(example.prompt)
                .font(GargantuaFonts.body.italic())
                .foregroundStyle(GargantuaColors.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(GargantuaSpacing.space4)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(example.prompt, forType: .string)
        #endif
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { didCopy = false }
        }
    }
}
