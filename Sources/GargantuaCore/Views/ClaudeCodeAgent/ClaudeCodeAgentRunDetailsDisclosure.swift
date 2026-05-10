import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

struct ClaudeCodeAgentRunDetailsDisclosure: View {
    @Binding var isExpanded: Bool
    @Binding var didCopyPrompt: Bool
    let selectedTemplate: ClaudeCodeAgentPromptTemplate
    let userContext: String
    let configurationStore: ClaudeCodeAgentConfigurationStore
    let sessionsRootPath: String

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                runDetailMetadata
                Divider().overlay(GargantuaColors.borderSoft)
                runPromptPreview
            }
            .padding(.top, GargantuaSpacing.space3)
        } label: {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.ink3)
                Text("Run details")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                Text("— see exactly what gets sent to Claude")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private var runDetailMetadata: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            metadataRow(label: "Model", value: previewModelLabel)
            metadataRow(label: "MCP server", value: "gargantua (local)")
            metadataRow(label: "Allowed tools", value: previewToolList)
            metadataRow(label: "Working dir", value: previewWorkingDirectoryLabel)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runPromptPreview: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text("Full prompt")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                Spacer()
                Button {
                    copyPromptToPasteboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopyPrompt ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(didCopyPrompt ? "Copied" : "Copy")
                            .font(GargantuaFonts.caption)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Copy the full prompt to the clipboard")
            }

            ScrollView {
                Text(renderedPrompt)
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GargantuaSpacing.space3)
            }
            .frame(maxHeight: 280)
            .background(GargantuaColors.surface3)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
    }

    private var renderedPrompt: String {
        ClaudeCodeAgentPromptBuilder.prompt(
            template: selectedTemplate,
            userContext: userContext
        )
    }

    private var previewToolList: String {
        ClaudeCodeAgentPromptBuilder.readOnlyToolAllowlist.joined(separator: ", ")
    }

    private var previewModelLabel: String {
        let configuration = configurationStore.load()
        let trimmed = configuration.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Claude Code CLI default" : trimmed
    }

    private var previewWorkingDirectoryLabel: String {
        "\(sessionsRootPath)/<per-session>"
    }

    private func copyPromptToPasteboard() {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(renderedPrompt, forType: .string)
        #endif
        didCopyPrompt = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { didCopyPrompt = false }
        }
    }
}
