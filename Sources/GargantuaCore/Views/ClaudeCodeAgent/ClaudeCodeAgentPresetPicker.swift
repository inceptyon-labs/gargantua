import SwiftUI

struct ClaudeCodeAgentPresetPicker: View {
    @Binding var selectedTemplate: ClaudeCodeAgentPromptTemplate
    @Binding var userContext: String

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("Preset")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)

            presetMenu

            Text(selectedTemplate.summary)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            AgentRunTryPromptChips(template: selectedTemplate, userContext: $userContext)
        }
    }

    /// Three pill buttons, one per preset, all visible at once. Replaces an
    /// earlier Menu dropdown that hid the alternatives behind a chevron —
    /// users were asking "what is the Preset? there is only one?" because
    /// the dropdown affordance wasn't obvious. With the vertical layout
    /// freeing horizontal space, we can show the full set unambiguously.
    private var presetMenu: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            ForEach(ClaudeCodeAgentPromptTemplate.allCases) { template in
                presetPill(template)
            }
            Spacer(minLength: 0)
        }
    }

    private func presetPill(_ template: ClaudeCodeAgentPromptTemplate) -> some View {
        let isSelected = template == selectedTemplate
        return Button {
            selectedTemplate = template
        } label: {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: template.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : GargantuaColors.accent)
                Text(template.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? .white : GargantuaColors.ink)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(isSelected ? GargantuaColors.accent : GargantuaColors.surface3)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(
                        isSelected ? Color.clear : GargantuaColors.borderSoft,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preset: \(template.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Tap-to-fill chip strip surfaced beneath the preset summary. Each chip
/// writes its prompt body into `userContext` so the user can run as-is or
/// edit before pressing Start. Hidden once the user has typed anything so
/// in-progress text isn't clobbered.
private struct AgentRunTryPromptChips: View {
    let template: ClaudeCodeAgentPromptTemplate
    @Binding var userContext: String

    var body: some View {
        let chips = ClaudeCodeAgentHelpContent.chips(for: template)
        let trimmed = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chips.isEmpty, trimmed.isEmpty {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                Text("TRY")
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink3)

                // FlowLayout (shared with ProfileListView's tag chips) wraps
                // chips to additional rows when they overflow the prompt
                // panel's width — important now that each preset surfaces
                // 3-4 chips instead of 1-2.
                FlowLayout(spacing: GargantuaSpacing.space2) {
                    ForEach(chips) { chip in
                        chipButton(chip)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, GargantuaSpacing.space1)
        }
    }

    private func chipButton(_ chip: ClaudeCodeAgentHelpContent.ExamplePrompt) -> some View {
        Button {
            userContext = chip.prompt
        } label: {
            Text(chip.chipLabel)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)
                .padding(.horizontal, GargantuaSpacing.space3)
                .padding(.vertical, GargantuaSpacing.space1)
                .background(GargantuaColors.surface3)
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(GargantuaColors.borderSoft, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
        .help(chip.prompt)
        .accessibilityLabel("Try prompt: \(chip.chipLabel)")
        .accessibilityHint("Fills the prompt field with an example question")
    }
}
