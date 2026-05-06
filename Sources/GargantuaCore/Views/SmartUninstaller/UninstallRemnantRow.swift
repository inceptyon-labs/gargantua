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
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(isLocked ? GargantuaColors.ink3 : GargantuaColors.ink)
                        .lineLimit(1)

                    if item.isReceiptEvidence {
                        receiptBadge
                    }
                }

                Text(item.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let pkgID = item.receiptPkgID {
                    Text(pkgID)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(item.explanation)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(item.isReceiptEvidence ? 3 : 2)
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

    private var receiptBadge: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
            Text("RECEIPT")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.6)
        }
        .foregroundStyle(GargantuaColors.ink2)
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, 2)
        .background(Capsule().fill(GargantuaColors.surface3))
        .overlay(Capsule().stroke(GargantuaColors.borderSoft, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let safety = item.safety.rawValue
        let state = isSelected ? "selected" : "not selected"
        let evidence = item.isReceiptEvidence
            ? ", pkgutil receipt evidence\(item.receiptPkgID.map { " from \($0)" } ?? "")"
            : ""
        if isLocked {
            return "\(name), \(safety)\(evidence), locked"
        }
        return "\(name), \(safety)\(evidence), \(state), \(AlertItem.formatBytes(item.size))"
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
