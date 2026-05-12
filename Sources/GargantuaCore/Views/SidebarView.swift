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
        ("1", [.command, .shift]), ("2", [.command, .shift]),
        ("3", [.command, .shift]), ("4", [.command, .shift]),
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
                    GargantuaSidebarBrandHeader(isCollapsed: isCollapsed)
                        .padding(.horizontal, GargantuaSpacing.space4)

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
            //   Items 11+ → Cmd+Shift+1…
            ForEach(Array(allItems.enumerated()), id: \.element.id) { index, item in
                if let shortcut = Self.shortcut(for: index) {
                    Button("") { selection = item.id }
                        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                        .hidden()
                }
            }

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

private struct GargantuaSidebarBrandHeader: View {
    let isCollapsed: Bool

    var body: some View {
        let size: CGFloat = isCollapsed ? 32 : 66
        let height: CGFloat = isCollapsed ? 88 : 132
        GargantuaBrandMark()
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: height)
            .accessibilityLabel("Gargantua")
    }
}

private struct GargantuaBrandMark: View {
    var body: some View {
        Group {
            if let image = Self.image {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(GargantuaColors.surface2)
                    .overlay {
                        Image(systemName: "circle.hexagongrid.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(GargantuaColors.accent)
                    }
            }
        }
    }

    private static let image: Image? = {
        guard let url = Bundle.module.url(
            forResource: "gargantua-logo",
            withExtension: "png",
            subdirectory: "Brand"
        ) else {
            return nil
        }

        #if os(macOS)
            guard let nsImage = NSImage(contentsOf: url) else { return nil }
            return Image(nsImage: nsImage)
        #elseif os(iOS)
            guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
            return Image(uiImage: uiImage)
        #else
            return nil
        #endif
    }()
}
