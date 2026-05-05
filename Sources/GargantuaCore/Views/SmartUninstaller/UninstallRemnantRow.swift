import SwiftUI

/// A single remnant row in the plan review list — checkbox (locked when
/// protected), filename, full path, explanation, size. The row background
/// is tinted by safety classification per DESIGN.md §5 Scan Rows (12%
/// safe / review / protected tint).
struct RemnantRow: View {
    let item: RemnantItem
    let isSelected: Bool
    let isLocked: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
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
                    .lineLimit(2)
            }

            Spacer()

            Text(AlertItem.formatBytes(item.size))
                .font(GargantuaFonts.monoData)
                .foregroundStyle(GargantuaColors.ink2)
        }
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .background(item.safety.tintBackground)
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
