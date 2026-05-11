import Foundation
import SwiftUI

extension DeveloperToolsView {
    var header: some View {
        PageHeaderView(
            title: "Developer Tools",
            subtitle: "Run each tool's own cleanup commands. Brew, Docker, Xcode, pnpm, Go, Cargo — they know what's safe to release.",
            subtitleStyle: .voice
        ) {
            HStack(spacing: GargantuaSpacing.space3) {
                if session.phase != .idle {
                    backButton
                    refreshButton
                }
            }
        }
    }

    func supportedToolsStrip(availabilities: [DeveloperToolAvailability]) -> some View {
        let availabilityByTool = Dictionary(uniqueKeysWithValues: availabilities.map { ($0.tool, $0) })

        return HStack(spacing: GargantuaSpacing.space3) {
            Text("SUPPORTED")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GargantuaSpacing.space2) {
                    ForEach(DeveloperTool.allCases) { tool in
                        let availability = availabilityByTool[tool]
                        supportedToolChip(tool: tool, isInstalled: availability?.isInstalled)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }

    func supportedToolChip(tool: DeveloperTool, isInstalled: Bool?) -> some View {
        let resolved = isInstalled == true
        return HStack(spacing: GargantuaSpacing.space1) {
            DeveloperToolLogoBadge(
                tool: tool,
                size: 14,
                showsBackground: false,
                isMuted: !resolved
            )
            Text(tool.displayName)
                .font(GargantuaFonts.caption)
                .lineLimit(1)
        }
        .foregroundStyle(resolved ? GargantuaColors.ink : GargantuaColors.ink3)
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(resolved ? GargantuaColors.accent.opacity(0.18) : GargantuaColors.surface3)
        )
        .overlay(
            Capsule()
                .stroke(resolved ? GargantuaColors.accent.opacity(0.45) : GargantuaColors.borderSoft, lineWidth: 1)
        )
        .help(chipHelp(tool: tool, isInstalled: isInstalled))
    }

    func chipHelp(tool: DeveloperTool, isInstalled: Bool?) -> String {
        switch isInstalled {
        case .some(true):
            "\(tool.displayName) detected"
        case .some(false):
            "\(tool.displayName) not detected"
        case .none:
            "\(tool.displayName) supported"
        }
    }

    var backButton: some View {
        Button(action: returnToIdle) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to idle")
    }

    var refreshButton: some View {
        Button {
            Task { await refreshAll() }
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("Refresh")
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help("Re-check installed tools and reload previews (⌘R)")
        .accessibilityLabel("Refresh previews")
    }
}
