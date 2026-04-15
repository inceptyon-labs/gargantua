import Foundation
import Testing
@testable import GargantuaCore

@Suite("SafetyLevel")
struct SafetyLevelTests {
    @Test("Safe items are selected by default")
    func safeSelectedByDefault() {
        #expect(SafetyLevel.safe.isSelectedByDefault == true)
    }

    @Test("Review items are not selected by default")
    func reviewNotSelected() {
        #expect(SafetyLevel.review.isSelectedByDefault == false)
    }

    @Test("Protected items are not selected by default")
    func protectedNotSelected() {
        #expect(SafetyLevel.protected_.isSelectedByDefault == false)
    }

    @Test("Safe and review items are actionable")
    func actionability() {
        #expect(SafetyLevel.safe.isActionable == true)
        #expect(SafetyLevel.review.isActionable == true)
        #expect(SafetyLevel.protected_.isActionable == false)
    }

    @Test("Confirmation tiers scale with risk")
    func confirmationTiers() {
        #expect(SafetyLevel.safe.confirmationTier == .singleButton)
        #expect(SafetyLevel.review.confirmationTier == .summaryDialog)
        #expect(SafetyLevel.protected_.confirmationTier == .fullModal)
    }

    @Test("Codable round-trip preserves values")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for level in SafetyLevel.allCases {
            let data = try encoder.encode(level)
            let decoded = try decoder.decode(SafetyLevel.self, from: data)
            #expect(decoded == level)
        }
    }

    @Test("Protected encodes as 'protected' not 'protected_'")
    func protectedEncoding() throws {
        let data = try JSONEncoder().encode(SafetyLevel.protected_)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"protected\"")
    }
}
