import Foundation
import Testing
@testable import GargantuaCore

@Suite("Developer Tools sidebar wiring")
struct DeveloperToolsSidebarTests {

    @Test("TOOLS section includes devTools entry")
    func toolsSectionHasDevTools() {
        let tools = SidebarSection.defaultSections.first { $0.id == "tools" }
        let ids = tools?.items.map(\.id) ?? []
        #expect(ids.contains("devTools"))
    }

    @Test("devTools label is user-facing")
    func devToolsLabel() {
        let item = SidebarSection.defaultSections
            .flatMap(\.items)
            .first { $0.id == "devTools" }
        #expect(item?.label == "Developer Tools")
        let icon = item?.icon ?? ""
        #expect(icon.isEmpty == false)
    }
}
