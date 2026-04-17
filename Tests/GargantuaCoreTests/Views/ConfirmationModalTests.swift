import Testing
import Foundation
@testable import GargantuaCore

// MARK: - Test Helpers

private func makeScanResult(
    id: String = "item_\(UUID().uuidString.prefix(4))",
    name: String = "Test Item",
    safety: SafetyLevel = .safe,
    size: Int64 = 1_000_000
) -> ScanResult {
    ScanResult(
        id: id,
        name: name,
        path: "/tmp/\(id)",
        size: size,
        safety: safety,
        confidence: 90,
        explanation: "Test item",
        source: SourceAttribution(name: "Test"),
        category: "test"
    )
}

// MARK: - Tier Determination

@Suite("Confirmation Tier Determination")
struct ConfirmationTierTests {
    @Test("All safe items → singleButton")
    func allSafe() {
        let items = [
            makeScanResult(id: "a", safety: .safe),
            makeScanResult(id: "b", safety: .safe),
            makeScanResult(id: "c", safety: .safe),
        ]
        #expect(confirmationTier(for: items) == .singleButton)
    }

    @Test("Single safe item → singleButton")
    func singleSafe() {
        let items = [makeScanResult(safety: .safe)]
        #expect(confirmationTier(for: items) == .singleButton)
    }

    @Test("Mixed safe + review → summaryDialog")
    func mixedSafeReview() {
        let items = [
            makeScanResult(id: "a", safety: .safe),
            makeScanResult(id: "b", safety: .review),
        ]
        #expect(confirmationTier(for: items) == .summaryDialog)
    }

    @Test("All review → summaryDialog")
    func allReview() {
        let items = [
            makeScanResult(id: "a", safety: .review),
            makeScanResult(id: "b", safety: .review),
        ]
        #expect(confirmationTier(for: items) == .summaryDialog)
    }

    @Test("Any protected → fullModal")
    func anyProtected() {
        let items = [
            makeScanResult(id: "a", safety: .safe),
            makeScanResult(id: "b", safety: .review),
            makeScanResult(id: "c", safety: .protected_),
        ]
        #expect(confirmationTier(for: items) == .fullModal)
    }

    @Test("All protected → fullModal")
    func allProtected() {
        let items = [
            makeScanResult(id: "a", safety: .protected_),
            makeScanResult(id: "b", safety: .protected_),
        ]
        #expect(confirmationTier(for: items) == .fullModal)
    }

    @Test("Protected overrides review in tier selection")
    func protectedOverridesReview() {
        let items = [
            makeScanResult(id: "a", safety: .review),
            makeScanResult(id: "b", safety: .protected_),
        ]
        #expect(confirmationTier(for: items) == .fullModal)
    }

    @Test("Empty items → singleButton (degenerate case)")
    func emptyItems() {
        #expect(confirmationTier(for: []) == .singleButton)
    }
}

// MARK: - Total Size Computation

@Suite("Confirmation Total Computation")
struct ConfirmationTotalTests {
    @Test("Total size sums all items")
    func totalSize() {
        let items = [
            makeScanResult(id: "a", size: 1_000_000_000),
            makeScanResult(id: "b", size: 500_000_000),
            makeScanResult(id: "c", size: 200_000_000),
        ]
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        #expect(total == 1_700_000_000)
    }

    @Test("Single item total equals its size")
    func singleItem() {
        let items = [makeScanResult(size: 18_200_000_000)]
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        #expect(total == 18_200_000_000)
    }

    @Test("Total line format matches expected pattern")
    func totalLineFormat() {
        // formatBytes truncates to integer for values >= 10 in their unit
        let sizeText = AlertItem.formatBytes(18_200_000_000)
        #expect(sizeText == "18 GB")

        // Sub-10 values keep one decimal
        let smallSizeText = AlertItem.formatBytes(5_300_000_000)
        #expect(smallSizeText == "5.3 GB")

        let countText = "45 items"
        let expected = cleanupTotalLineText(itemCount: 45, totalSize: 18_200_000_000, method: .trash)
        #expect(countText == "45 items")
        #expect(expected == "Clean 45 items (18 GB) - Move to Trash")
    }

    @Test("Total line reflects permanent delete method")
    func totalLineDeleteFormat() {
        let expected = cleanupTotalLineText(itemCount: 1, totalSize: 5_300_000_000, method: .delete)
        #expect(expected == "Clean 1 item (5.3 GB) - Delete Permanently")
    }

    @Test("Singular item count: '1 item' not '1 items'")
    func singularCount() {
        let expected = cleanupTotalLineText(itemCount: 1, totalSize: 100, method: .trash)
        #expect(expected.contains("Clean 1 item"))
    }
}

// MARK: - Safety Level Tier Alignment

@Suite("Safety Level and Tier Alignment")
struct TierAlignmentTests {
    @Test("Individual SafetyLevel.confirmationTier matches determineTier for homogeneous sets")
    func homogeneousTierAlignment() {
        let safeItems = [makeScanResult(id: "a", safety: .safe)]
        #expect(confirmationTier(for: safeItems) == SafetyLevel.safe.confirmationTier)

        let reviewItems = [makeScanResult(id: "b", safety: .review)]
        #expect(confirmationTier(for: reviewItems) == SafetyLevel.review.confirmationTier)

        let protectedItems = [makeScanResult(id: "c", safety: .protected_)]
        #expect(confirmationTier(for: protectedItems) == SafetyLevel.protected_.confirmationTier)
    }

    @Test("Tier escalates to highest risk, never de-escalates")
    func escalationOrder() {
        let tiers: [ConfirmationTier] = [.singleButton, .summaryDialog, .fullModal]

        // Adding review to safe escalates
        let safeOnly = confirmationTier(for: [makeScanResult(id: "a", safety: .safe)])
        let withReview = confirmationTier(for: [
            makeScanResult(id: "b", safety: .safe),
            makeScanResult(id: "c", safety: .review),
        ])
        #expect(tiers.firstIndex(of: withReview)! > tiers.firstIndex(of: safeOnly)!)

        // Adding protected escalates further
        let withProtected = confirmationTier(for: [
            makeScanResult(id: "d", safety: .safe),
            makeScanResult(id: "e", safety: .review),
            makeScanResult(id: "f", safety: .protected_),
        ])
        #expect(tiers.firstIndex(of: withProtected)! > tiers.firstIndex(of: withReview)!)
    }
}
