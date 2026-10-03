import SwiftUI
#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// Grouped sidebar with section labels, SF Symbol icons, and active/hover states.
///
/// Implements DESIGN.md §5 sidebar spec:
/// - 200pt wide, `void` background, right `border` separator.
/// - Section labels: `ink4`, 10px, 600 weight, uppercase, 0.08em tracking.
/// - Active item: `surface2` background, `borderEm` outline, and a 3pt `accent`
///   capsule anchored to the leading rail.
/// - Hover: `surface1` background.
public struct SidebarView: View {
    @Binding public var selection: String?
    public var sections: [SidebarSection]
    @ObservedObject private var mcpStatusModel: MCPServerStatusViewModel
    @AppStorage("sidebar.collapsed") private var isCollapsed: Bool = false

    private static let expandedWidth: CGFloat = 200
    private static let collapsedWidth: CGFloat = 64

    @MainActor
    public init(
        selection: Binding<String?>,
        sections: [SidebarSection] = SidebarSection.defaultSections
    ) {
        self._selection = selection
        self.sections = sections
        self.mcpStatusModel = MCPServerStatusViewModel()
    }

    @MainActor
    public init(
        selection: Binding<String?>,
        sections: [SidebarSection] = SidebarSection.defaultSections,
        mcpStatusModel: MCPServerStatusViewModel
    ) {
        self._selection = selection
        self.sections = sections
        self.mcpStatusModel = mcpStatusModel
    }

    /// All items flattened in section order, for keyboard shortcut indexing.
    private var allItems: [SidebarItem] {
        sections.flatMap(\.items)
    }

    private static let shortcutMap: [(key: KeyEquivalent, modifiers: EventModifiers)] = [
        ("1", .command), ("2", .command), ("3", .command),
        ("4", .command), ("5", .command), ("6", .command),
        ("7", .command), ("8", .command), ("9", .command),
        ("0", .command),
        // Not ⇧⌘: ⇧⌘3/4/5 are macOS screenshot shortcuts.
        ("1", [.command, .option]), ("2", [.command, .option]), ("3", [.command, .option]),
        ("4", [.command, .option]), ("5", [.command, .option]), ("6", [.command, .option]),
    ]

    private static func shortcut(
        for index: Int
    ) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
        guard index < shortcutMap.count else { return nil }
        return shortcutMap[index]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        SidebarSectionView(
                            section: section,
                            selection: $selection,
                            isCollapsed: isCollapsed
                        )
                        .padding(.top, GargantuaSpacing.space3)
                    }
                }
                .padding(.bottom, GargantuaSpacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)

            SidebarFooter(
                mcpStatusModel: mcpStatusModel,
                isCollapsed: isCollapsed,
                onToggleCollapse: toggleCollapsed
            )
        }
        .frame(width: isCollapsed ? Self.collapsedWidth : Self.expandedWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GargantuaColors.void_)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(width: 1)
        }
        .background {
            // Hidden buttons covering all sidebar items:
            //   Items 1–9 → Cmd+1…Cmd+9
            //   Item 10   → Cmd+0
            //   Items 11+ → Cmd+Option+1…
            ForEach(Array(allItems.enumerated()), id: \.element.id) { index, item in
                if let shortcut = Self.shortcut(for: index) {
                    Button("") { selection = item.id }
                        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                        .hidden()
                }
            }

            // Cmd+, opens Settings, as in other Mac apps.
            Button("") { selection = "settings" }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()

            // Cmd+Option+S to toggle the sidebar.
            Button("", action: toggleCollapsed)
                .keyboardShortcut("s", modifiers: [.command, .option])
                .hidden()
        }
    }

    private func toggleCollapsed() {
        withAnimation(.smooth(duration: 0.35)) {
            isCollapsed.toggle()
        }
    }
}
