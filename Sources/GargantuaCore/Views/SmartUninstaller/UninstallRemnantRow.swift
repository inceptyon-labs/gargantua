import SwiftUI

/// A single remnant row in the plan review list — safety-coloured left
/// border, checkbox (locked when the item is protected), filename, full
/// path, explanation, and size.
struct RemnantRow: View {
    let item: RemnantItem
    let isSelected: Bool
    let isLocked: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Rectangle()
                .fill(item.safety.accentColor)
                .frame(width: 3)

            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(checkboxColor)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .accessibilityLabel(accessibilityLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isLocked ? GargantuaColors.ink3 : GargantuaColors.ink)
                    .lineLimit(1)

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.explanation)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.trailing, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private var checkboxColor: Color {
        if isLocked { return GargantuaColors.ink4 }
        return isSelected ? GargantuaColors.accent : GargantuaColors.ink3
    }

    private var accessibilityLabel: String {
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let safety = item.safety.rawValue
        let state = isSelected ? "selected" : "not selected"
        if isLocked {
            return "\(name), \(safety), locked"
        }
        return "\(name), \(safety), \(state), \(AlertItem.formatBytes(item.size))"
    }
}

// MARK: - Display helpers

extension SafetyLevel {
    var accentColor: Color {
        switch self {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

extension RemnantCategory {
    /// Human-readable label used in the plan review UI.
    public var displayLabel: String {
        switch self {
        case .supportFiles: "Support Files"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .launchAgents: "Launch Agents"
        case .launchDaemons: "Launch Daemons"
        case .logs: "Logs"
        case .savedState: "Saved State"
        case .cookies: "Cookies"
        case .webData: "Web Data"
        case .helpers: "Helpers"
        case .other: "Other"
        }
    }
}
