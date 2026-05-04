import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case ai = "AI"
    case automation = "Automation"
    case network = "Network"
    case storage = "Storage"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ai: "sparkles"
        case .automation: "clock.arrow.circlepath"
        case .network: "dot.radiowaves.left.and.right"
        case .storage: "externaldrive"
        case .about: "info.circle"
        }
    }

    var helpText: String {
        switch self {
        case .ai: "AI engines, cloud providers, and agent runtimes."
        case .automation: "Scheduled scans and menu bar widget."
        case .network: "MCP server transport for external clients."
        case .storage: "Scan roots, exclusions, and protected paths."
        case .about: "Updates, version, and licensing."
        }
    }
}

/// Top tab bar for the settings pane. One Surface-1 row, equal-padded items,
/// selected state uses a Surface-3 capsule with a Border-Em stroke. No glow.
/// Cmd-1..5 jumps directly to the matching tab.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, tab in
                tabButton(tab, index: index)
            }
        }
        .padding(GargantuaSpacing.space1)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.border, lineWidth: 1)
        )
    }

    private func tabButton(_ tab: SettingsTab, index: Int) -> some View {
        let isSelected = selection == tab
        let shortcutCharacter = Character("\(index + 1)")
        return Button(action: { selection = tab }) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                Text(tab.rawValue)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink)
            .opacity(isSelected ? 1 : 0.75)
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .frame(maxWidth: .infinity)
            .background(isSelected ? GargantuaColors.surface3 : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(isSelected ? GargantuaColors.borderEm : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(shortcutCharacter), modifiers: .command)
        .help("\(tab.helpText) (⌘\(index + 1))")
    }
}
