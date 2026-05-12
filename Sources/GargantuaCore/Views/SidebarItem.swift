import Foundation

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
                SidebarItem(id: "backgroundItems", label: "Background Items", icon: "clock.badge.questionmark"),
                SidebarItem(id: "processInventory", label: "Processes", icon: "cpu"),
            ]
        ),
        SidebarSection(
            id: "tools",
            label: "TOOLS",
            items: [
                SidebarItem(id: "devTools", label: "Developer Tools", icon: "wrench.and.screwdriver"),
                SidebarItem(id: "devPurge", label: "Dev Artifact Purge", icon: "hammer"),
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
