import Testing
import Foundation
@testable import GargantuaCore

@Suite("DeepCleanResultsTab")
struct DeepCleanResultsTabTests {
    @Test("Tabs render in Clean → Organize order")
    func ordering() {
        #expect(DeepCleanResultsTab.allCases == [.clean, .organize])
    }

    @Test("Each tab has distinct label + icon")
    func metadataDistinct() {
        let labels = Set(DeepCleanResultsTab.allCases.map(\.label))
        let icons = Set(DeepCleanResultsTab.allCases.map(\.systemImage))
        #expect(labels.count == DeepCleanResultsTab.allCases.count)
        #expect(icons.count == DeepCleanResultsTab.allCases.count)
    }

    @Test("Stable raw values are safe for persistence")
    func rawValuesStable() {
        #expect(DeepCleanResultsTab.clean.rawValue == "clean")
        #expect(DeepCleanResultsTab.organize.rawValue == "organize")
    }
}
