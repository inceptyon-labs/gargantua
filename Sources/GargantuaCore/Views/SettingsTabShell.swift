import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case ai = "AI"
    case automation = "General"
    case network = "Network"
    case storage = "Scope"
    case license = "License"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ai: "sparkles"
        case .automation: "gearshape"
        case .network: "dot.radiowaves.left.and.right"
        case .storage: "scope"
        case .license: "key.fill"
        case .about: "info.circle"
        }
    }

    var helpText: String {
        switch self {
        case .ai: "AI engines, cloud providers, and agent runtimes."
        case .automation: "Appearance, scheduled scans, and menu bar widget."
        case .network: "MCP server transport for external clients."
        case .storage: "Scan roots, exclusions, and protected paths."
        case .license: "Activate Gargantua or check your trial status."
        case .about: "Updates and version."
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
        return Button(action: { selection = tab }, label: {
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
        })
        .buttonStyle(.plain)
        // ⌃⌘, not ⌘: the sidebar owns ⌘1–⌘9 and stays mounted beside Settings.
        .keyboardShortcut(KeyEquivalent(shortcutCharacter), modifiers: [.command, .control])
        .help("\(tab.helpText) (⌃⌘\(index + 1))")
    }
}
