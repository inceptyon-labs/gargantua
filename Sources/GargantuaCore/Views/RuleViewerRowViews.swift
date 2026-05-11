import SwiftUI

struct RuleCategory: Identifiable {
    let name: String
    let rules: [ScanRule]
    var id: String { name }

    var icon: String {
        switch name {
        case "browser": "globe"
        case "apps": "app.badge"
        case "developer": "hammer"
        case "system": "gearshape.2"
        default: "folder"
        }
    }

    var displayName: String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}

struct CategoryRow: View {
    let category: RuleCategory
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? GargantuaColors.accent : GargantuaColors.ink2)
                    .frame(width: 18, alignment: .center)

                Text(category.displayName)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)

                Spacer()

                Text("\(category.rules.count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                isSelected ? GargantuaColors.surface3 :
                    isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct RuleRow: View {
    let rule: ScanRule
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space3) {
                Circle()
                    .fill(safetyColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)
                        .lineLimit(1)

                    Text(rule.source.name)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(rule.confidence)%")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                isSelected ? GargantuaColors.surface3 :
                    isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var safetyColor: Color {
        switch rule.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}
