import SwiftUI
#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

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
    /// The sidebar sections: overview, clean, analyze, tools, configure.
    public static let defaultSections: [SidebarSection] = [
        SidebarSection(
            id: "overview",
            label: "OVERVIEW",
            items: [
                SidebarItem(id: "dashboard", label: "Dashboard", icon: "gauge.with.dots.needle.33percent")
            ]
        ),
        SidebarSection(
            id: "clean",
            label: "CLEAN",
            items: [
                SidebarItem(id: "deepClean", label: "Deep Clean", icon: "bubbles.and.sparkles"),
                SidebarItem(id: "smartUninstaller", label: "Smart Uninstaller", icon: "trash.slash"),
                SidebarItem(id: "duplicateFinder", label: "Duplicate Finder", icon: "doc.on.doc"),
                SidebarItem(id: "fileHealth", label: "File Health", icon: "stethoscope"),
            ]
        ),
        SidebarSection(
            id: "analyze",
            label: "ANALYZE",
            items: [
                SidebarItem(id: "diskExplorer", label: "Disk Explorer", icon: "internaldrive"),
                SidebarItem(id: "aiModels", label: "AI Models", icon: "brain"),
            ]
        ),
        SidebarSection(
            id: "tools",
            label: "TOOLS",
            items: [
                SidebarItem(id: "devPurge", label: "Dev Artifact Purge", icon: "hammer"),
                SidebarItem(id: "devTools", label: "Developer Tools", icon: "wrench.and.screwdriver"),
                SidebarItem(id: "agentSessions", label: "Agent Run", icon: "brain.head.profile"),
            ]
        ),
        SidebarSection(
            id: "configure",
            label: "CONFIGURE",
            items: [
                SidebarItem(id: "profiles", label: "Profiles", icon: "person.2"),
                SidebarItem(id: "rules", label: "Rules", icon: "doc.text"),
                SidebarItem(id: "settings", label: "Settings", icon: "gearshape"),
            ]
        ),
    ]
}

// MARK: - Sidebar View

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
            GargantuaSidebarBrandHeader(isCollapsed: isCollapsed)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space4)

            ForEach(sections) { section in
                SidebarSectionView(
                    section: section,
                    selection: $selection,
                    isCollapsed: isCollapsed
                )
                .padding(.top, GargantuaSpacing.space3)
            }

            Spacer()

            SidebarFooter(
                mcpStatusModel: mcpStatusModel,
                isCollapsed: isCollapsed,
                onToggleCollapse: toggleCollapsed
            )
        }
        .padding(.top, GargantuaSpacing.space4)
        .frame(width: isCollapsed ? Self.collapsedWidth : Self.expandedWidth)
        .frame(maxHeight: .infinity)
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
        GargantuaBrandMark()
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, alignment: .center)
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

// MARK: - Section View

private struct SidebarSectionView: View {
    let section: SidebarSection
    @Binding var selection: String?
    let isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            if !isCollapsed {
                Text(section.label)
                    .font(GargantuaFonts.sectionLabel)
                    .foregroundStyle(GargantuaColors.ink4)
                    .tracking(0.8) // 0.08em × 10px = 0.8pt
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.bottom, GargantuaSpacing.space1)
                    .transition(.opacity)
            }

            ForEach(section.items) { item in
                SidebarItemRow(
                    item: item,
                    isSelected: selection == item.id,
                    isCollapsed: isCollapsed,
                    onSelect: { selection = item.id }
                )
            }
        }
    }
}

// MARK: - Tooltip Bridge

#if os(macOS)
    /// AppKit-bridged tooltip. SwiftUI's `.help()` modifier is unreliable on
    /// macOS — particularly on `Button`s inside `VStack`s with overlay/background
    /// modifiers. This bridges directly to `NSView.toolTip` via an overlay
    /// `NSView` that ignores hit testing so clicks still pass through to the
    /// underlying SwiftUI control.
    private final class PassThroughToolTipNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct ToolTipBridge: NSViewRepresentable {
        let text: String

        func makeNSView(context: Context) -> PassThroughToolTipNSView {
            let view = PassThroughToolTipNSView()
            view.toolTip = text
            return view
        }

        func updateNSView(_ nsView: PassThroughToolTipNSView, context: Context) {
            nsView.toolTip = text
        }
    }

    extension View {
        fileprivate func nativeToolTip(_ text: String) -> some View {
            overlay(ToolTipBridge(text: text))
        }
    }
#else
    extension View {
        fileprivate func nativeToolTip(_ text: String) -> some View {
            self
        }
    }
#endif

// MARK: - Item Row

private struct SidebarItemRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let isCollapsed: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private static let transitionDuration: Double = 0.12

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink3)
                    .frame(width: 20, alignment: .center)
                    .frame(maxWidth: isCollapsed ? .infinity : nil, alignment: .center)

                if !isCollapsed {
                    Text(item.label)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)
                        .lineLimit(1)
                        .transition(.opacity)

                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, isCollapsed ? GargantuaSpacing.space2 : GargantuaSpacing.space4)
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous)
                    .fill(rowBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: GargantuaRadius.medium, style: .continuous)
                            .stroke(isSelected ? GargantuaColors.borderEm : .clear, lineWidth: 1)
                    }
                    .padding(.horizontal, GargantuaSpacing.space2)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(GargantuaColors.accent)
                        .frame(width: 3, height: 22)
                        .padding(.leading, GargantuaSpacing.space1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .nativeToolTip(item.label)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: Self.transitionDuration), value: isSelected)
        .animation(.easeOut(duration: Self.transitionDuration), value: isHovered)
        .accessibilityLabel(item.label)
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

// MARK: - Footer

private struct SidebarFooter: View {
    @ObservedObject var mcpStatusModel: MCPServerStatusViewModel
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
                .padding(.horizontal, GargantuaSpacing.space3)

            if !isCollapsed {
                SystemInfoBar(mcpStatusModel: mcpStatusModel)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                if isCollapsed {
                    Spacer(minLength: 0)
                    CollapseToggle(
                        isCollapsed: isCollapsed,
                        onTap: onToggleCollapse
                    )
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    CollapseToggle(
                        isCollapsed: isCollapsed,
                        onTap: onToggleCollapse
                    )
                    .padding(.trailing, GargantuaSpacing.space3)
                }
            }
            .padding(.vertical, GargantuaSpacing.space2)
        }
    }
}

private struct CollapseToggle: View {
    let isCollapsed: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Image(
                systemName: isCollapsed
                    ? "sidebar.left"
                    : "sidebar.leading"
            )
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isHovered ? GargantuaColors.ink : GargantuaColors.ink3)
            .frame(width: 28, height: 22)
            .background {
                RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous)
                    .fill(isHovered ? GargantuaColors.surface2 : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .nativeToolTip(isCollapsed ? "Expand sidebar (⌥⌘S)" : "Collapse sidebar (⌥⌘S)")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }
}

// MARK: - System Info Bar

enum SidebarServiceIndicatorTone: Equatable {
    case active
    case attention
    case inactive
}

struct SidebarServiceIndicatorPresentation: Equatable {
    let label: String
    let status: String
    let detail: String
    let tone: SidebarServiceIndicatorTone

    static let native = SidebarServiceIndicatorPresentation(
        label: "Native",
        status: "Ready",
        detail: "Native scanner is available.",
        tone: .active
    )

    static func mcp(from snapshot: MCPServerStatusSnapshot) -> SidebarServiceIndicatorPresentation {
        switch snapshot.state {
        case .running:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: snapshot.transportMode.displayName,
                detail: "MCP server running over \(snapshot.transportMode.displayName).",
                tone: .active
            )
        case .starting:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: "Starting",
                detail: "MCP server is starting.",
                tone: .attention
            )
        case .error:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: "Error",
                detail: snapshot.lastErrorMessage ?? "MCP server reported an error.",
                tone: .attention
            )
        case .stopped:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: "Off",
                detail: "MCP server is not running.",
                tone: .inactive
            )
        }
    }

    static func tier3(
        configuration: ClaudeCodeAgentConfiguration,
        cliAvailable: Bool
    ) -> SidebarServiceIndicatorPresentation {
        guard configuration.isEnabled else {
            return SidebarServiceIndicatorPresentation(
                label: "Tier 3",
                status: "Off",
                detail: "Tier 3 Claude Code Agent is disabled.",
                tone: .inactive
            )
        }

        if cliAvailable {
            return SidebarServiceIndicatorPresentation(
                label: "Tier 3",
                status: "Ready",
                detail: "Tier 3 Claude Code Agent is enabled.",
                tone: .active
            )
        }

        return SidebarServiceIndicatorPresentation(
            label: "Tier 3",
            status: "Needs CLI",
            detail: "Tier 3 is enabled, but the Claude Code CLI is not available.",
            tone: .attention
        )
    }
}

/// Compact footer showing hardware model, macOS version, disk usage, engine status, MCP, and Tier 3.
struct SystemInfoBar: View {
    @ObservedObject var mcpStatusModel: MCPServerStatusViewModel

    @State private var hardwareModel: String?
    @State private var diskTotalGB: Int?
    @State private var diskUsedGB: Int?
    @State private var tier3Presentation = SidebarServiceIndicatorPresentation.tier3(
        configuration: ClaudeCodeAgentConfiguration(),
        cliAvailable: false
    )

    private let agentConfigurationStore = ClaudeCodeAgentConfigurationStore()
    private let agentCLIResolver = ClaudeCodeCLIResolver()

    private var mcpPresentation: SidebarServiceIndicatorPresentation {
        SidebarServiceIndicatorPresentation.mcp(from: mcpStatusModel.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            // Line 1: Hardware model · macOS version
            Text(hardwareLine)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)

            // Line 2: Disk usage
            Text(diskLine)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)
                .lineLimit(1)

            // Line 3: Runtime integrations
            HStack(spacing: GargantuaSpacing.space2) {
                statusIndicator(.native)

                Spacer().frame(width: GargantuaSpacing.space1)

                statusIndicator(mcpPresentation)

                Spacer().frame(width: GargantuaSpacing.space1)

                statusIndicator(tier3Presentation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .onAppear {
            refreshSystemInfo()
            refreshRuntimeStatus()
        }
        .task {
            await refreshRuntimeStatusLoop()
        }
    }

    // MARK: - Display Strings

    private var hardwareLine: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "macOS \(version.majorVersion).\(version.minorVersion)"
        if let model = hardwareModel {
            return "\(model) · \(macOS)"
        }
        return macOS
    }

    private var diskLine: String {
        if let used = diskUsedGB, let total = diskTotalGB {
            return "\(used) / \(total) GB used"
        }
        return "Disk info unavailable"
    }

    @ViewBuilder
    private func statusIndicator(_ presentation: SidebarServiceIndicatorPresentation) -> some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Circle()
                .fill(color(for: presentation.tone))
                .frame(width: 6, height: 6)

            Text(presentation.label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(textColor(for: presentation.tone))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help("\(presentation.label): \(presentation.status). \(presentation.detail)")
        .accessibilityLabel("\(presentation.label) \(presentation.status)")
    }

    // MARK: - Data Collection

    private func refreshSystemInfo() {
        hardwareModel = Self.queryHardwareModel()
        refreshDisk()
    }

    private func refreshRuntimeStatus() {
        mcpStatusModel.refresh()
        let configuration = agentConfigurationStore.load()
        tier3Presentation = SidebarServiceIndicatorPresentation.tier3(
            configuration: configuration,
            cliAvailable: (try? agentCLIResolver.resolve(configuration: configuration)) != nil
        )
    }

    @MainActor
    private func refreshRuntimeStatusLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshRuntimeStatus()
        }
    }

    private func refreshDisk() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ) {
            if let totalBytes = attrs[.systemSize] as? UInt64 {
                diskTotalGB = Int(totalBytes / (1024 * 1024 * 1024))
            }
            if let freeBytes = attrs[.systemFreeSize] as? UInt64,
               let totalBytes = attrs[.systemSize] as? UInt64 {
                diskUsedGB = Int((totalBytes - freeBytes) / (1024 * 1024 * 1024))
            }
        }
    }

    private static func queryHardwareModel() -> String? {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let raw = String(cString: model)
        return Self.friendlyModelName(raw)
    }

    private static func friendlyModelName(_ raw: String) -> String {
        if raw.contains("MacBookPro") { return "MacBook Pro" }
        if raw.contains("MacBookAir") { return "MacBook Air" }
        if raw.contains("Macmini") { return "Mac mini" }
        if raw.contains("MacPro") { return "Mac Pro" }
        if raw.contains("iMac") { return "iMac" }
        if raw.contains("Mac") { return "Mac" }
        return raw
    }

    private func color(for tone: SidebarServiceIndicatorTone) -> Color {
        switch tone {
        case .active: GargantuaColors.safe
        case .attention: GargantuaColors.review
        case .inactive: GargantuaColors.ink4
        }
    }

    private func textColor(for tone: SidebarServiceIndicatorTone) -> Color {
        switch tone {
        case .active, .attention: GargantuaColors.ink3
        case .inactive: GargantuaColors.ink4
        }
    }
}
