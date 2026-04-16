import Testing
@testable import GargantuaCore

// MARK: - Sidebar Data Model

@Suite("SidebarSection")
struct SidebarSectionTests {
    @Test("Default sections has five groups")
    func defaultSectionCount() {
        #expect(SidebarSection.defaultSections.count == 5)
    }

    @Test("Default section IDs match expected groups")
    func defaultSectionIDs() {
        let ids = SidebarSection.defaultSections.map(\.id)
        #expect(ids == ["overview", "clean", "analyze", "tools", "configure"])
    }

    @Test("Default section labels are uppercase")
    func defaultSectionLabels() {
        let labels = SidebarSection.defaultSections.map(\.label)
        #expect(labels == ["OVERVIEW", "CLEAN", "ANALYZE", "TOOLS", "CONFIGURE"])
    }

    @Test("Each default section has at least one item")
    func defaultSectionsNonEmpty() {
        for section in SidebarSection.defaultSections {
            #expect(!section.items.isEmpty, "Section '\(section.label)' should have items")
        }
    }

    @Test("Default items have expected IDs")
    func defaultItemIDs() {
        let allIDs = SidebarSection.defaultSections.flatMap { $0.items.map(\.id) }
        #expect(allIDs.contains("dashboard"))
        #expect(allIDs.contains("deepClean"))
        #expect(allIDs.contains("diskExplorer"))
        #expect(allIDs.contains("devPurge"))
        #expect(allIDs.contains("settings"))
    }

    @Test("All item IDs are unique across sections")
    func itemIDsUnique() {
        let allIDs = SidebarSection.defaultSections.flatMap { $0.items.map(\.id) }
        #expect(Set(allIDs).count == allIDs.count, "Item IDs must be unique across all sections")
    }

    @Test("Every item has an SF Symbol icon name")
    func itemsHaveIcons() {
        for section in SidebarSection.defaultSections {
            for item in section.items {
                #expect(!item.icon.isEmpty, "Item '\(item.label)' should have an icon")
            }
        }
    }
}

// MARK: - SidebarItem Equatable

@Suite("SidebarItem")
struct SidebarItemTests {
    @Test("Items with same properties are equal")
    func equality() {
        let a = SidebarItem(id: "test", label: "Test", icon: "gear")
        let b = SidebarItem(id: "test", label: "Test", icon: "gear")
        #expect(a == b)
    }

    @Test("Items with different IDs are not equal")
    func inequality() {
        let a = SidebarItem(id: "a", label: "Test", icon: "gear")
        let b = SidebarItem(id: "b", label: "Test", icon: "gear")
        #expect(a != b)
    }
}
