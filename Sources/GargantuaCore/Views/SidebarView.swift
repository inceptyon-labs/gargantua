import SwiftUI

// MARK: - Sidebar Data Model

/// A navigation item in the sidebar.
public struct SidebarItem: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let icon: String // SF Symbol name

    public init(id: String, label: String, icon: String) {
        self.id = id
        self.label = label
        self.icon = icon
    }
}

/// A labeled group of sidebar items.
public struct SidebarSection: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let items: [SidebarItem]

    public init(id: String, label: String, items: [SidebarItem]) {
        self.id = id
        self.label = label
        self.items = items
    }
}

// MARK: - Default Sections

extension SidebarSection {
    /// The four sidebar sections defined in the design brief.
    public static let defaultSections: [SidebarSection] = [
        SidebarSection(
            id: "clean",
            label: "CLEAN",
            items: [
                SidebarItem(id: "deepClean", label: "Deep Clean", icon: "bubbles.and.sparkles")
            ]
        ),
        SidebarSection(
            id: "analyze",
            label: "ANALYZE",
            items: [
                SidebarItem(id: "diskExplorer", label: "Disk Explorer", icon: "internaldrive")
            ]
        ),
        SidebarSection(
            id: "tools",
            label: "TOOLS",
            items: [
                SidebarItem(id: "devPurge", label: "Dev Artifact Purge", icon: "hammer")
            ]
        ),
        SidebarSection(
            id: "configure",
            label: "CONFIGURE",
            items: [
                SidebarItem(id: "settings", label: "Settings", icon: "gearshape")
            ]
        ),
    ]
}

// MARK: - Sidebar View

/// Grouped sidebar with section labels, SF Symbol icons, and active/hover states.
///
/// 200px wide, `--void` background, right `--border` separator.
/// Section labels: `--ink-4`, 10px, 600 weight, uppercase, 0.08em tracking.
/// Active item: `--surface-2` background + 2px `--accent` left indicator.
/// Hover: `--surface-1` background.
public struct SidebarView: View {
    @Binding public var selection: String?
    public var sections: [SidebarSection]

    public init(selection: Binding<String?>, sections: [SidebarSection] = SidebarSection.defaultSections) {
        self._selection = selection
        self.sections = sections
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Divider()
                        .background(GargantuaColors.border)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space2)
                }

                SidebarSectionView(
                    section: section,
                    selection: $selection
                )
            }

            Spacer()
        }
        .padding(.top, GargantuaSpacing.space4)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(GargantuaColors.void_)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(width: 1)
        }
    }
}

// MARK: - Section View

private struct SidebarSectionView: View {
    let section: SidebarSection
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            Text(section.label)
                .font(GargantuaFonts.sectionLabel)
                .foregroundStyle(GargantuaColors.ink4)
                .tracking(0.8) // 0.08em at 10px
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space1)

            ForEach(section.items) { item in
                SidebarItemRow(
                    item: item,
                    isSelected: selection == item.id,
                    onSelect: { selection = item.id }
                )
            }
        }
    }
}

// MARK: - Item Row

private struct SidebarItemRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(width: 20, alignment: .center)

                Text(item.label)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)

                Spacer()
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, GargantuaSpacing.space4)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(GargantuaColors.accent)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return GargantuaColors.surface2
        } else if isHovered {
            return GargantuaColors.surface1
        }
        return .clear
    }
}
