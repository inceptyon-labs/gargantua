import Foundation
import Testing
@testable import GargantuaCore

@Suite("UninstallPlan")
struct UninstallPlanTests {

    static let app = AppInfoTests.sample

    static func remnant(
        id: String,
        category: RemnantCategory,
        size: Int64,
        safety: SafetyLevel
    ) -> RemnantItem {
        RemnantItem(
            id: id,
            appBundleID: app.bundleID,
            category: category,
            path: "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "test",
            source: SourceAttribution(name: app.name),
            ruleID: "test_rule"
        )
    }

    @Test("totalBytes sums bundle + all remnants")
    func totalBytes() {
        let bundle = Self.remnant(id: "bundle", category: .other, size: 500_000_000, safety: .safe)
        let plan = UninstallPlan(
            app: Self.app,
            appBundle: bundle,
            remnants: [
                Self.remnant(id: "r1", category: .caches, size: 100, safety: .safe),
                Self.remnant(id: "r2", category: .logs, size: 200, safety: .safe),
            ]
        )
        #expect(plan.totalBytes == 500_000_300)
    }

    @Test("allItems puts the bundle first, then remnants in discovery order")
    func allItemsOrder() {
        let bundle = Self.remnant(id: "bundle", category: .other, size: 1, safety: .safe)
        let r1 = Self.remnant(id: "r1", category: .caches, size: 1, safety: .safe)
        let r2 = Self.remnant(id: "r2", category: .logs, size: 1, safety: .safe)
        let plan = UninstallPlan(app: Self.app, appBundle: bundle, remnants: [r1, r2])
        let ids = plan.allItems.map(\.id)
        #expect(ids == ["bundle", "r1", "r2"])
    }

    @Test("allItems works with no bundle (remnants-only cleanup)")
    func allItemsNoBundle() {
        let r1 = Self.remnant(id: "r1", category: .caches, size: 1, safety: .safe)
        let plan = UninstallPlan(app: Self.app, remnants: [r1])
        #expect(plan.allItems.map(\.id) == ["r1"])
    }

    @Test("remnantsByCategory groups remnants, omitting the bundle")
    func groupedByCategory() {
        let bundle = Self.remnant(id: "bundle", category: .other, size: 1, safety: .safe)
        let plan = UninstallPlan(
            app: Self.app,
            appBundle: bundle,
            remnants: [
                Self.remnant(id: "c1", category: .caches, size: 1, safety: .safe),
                Self.remnant(id: "c2", category: .caches, size: 1, safety: .safe),
                Self.remnant(id: "l1", category: .logs, size: 1, safety: .safe),
            ]
        )
        let grouped = plan.remnantsByCategory
        #expect(grouped[.caches]?.count == 2)
        #expect(grouped[.logs]?.count == 1)
        #expect(grouped[.other] == nil)
    }

    @Test("actionableItems excludes protected items")
    func actionableFilters() {
        let plan = UninstallPlan(
            app: Self.app,
            remnants: [
                Self.remnant(id: "safe", category: .caches, size: 1, safety: .safe),
                Self.remnant(id: "review", category: .preferences, size: 1, safety: .review),
                Self.remnant(id: "prot", category: .launchDaemons, size: 1, safety: .protected_),
            ]
        )
        let ids = plan.actionableItems.map(\.id)
        #expect(ids == ["safe", "review"])
    }

    @Test("Codable round-trip preserves plan structure")
    func codableRoundTrip() throws {
        let bundle = Self.remnant(id: "bundle", category: .other, size: 1, safety: .safe)
        let plan = UninstallPlan(
            app: Self.app,
            appBundle: bundle,
            remnants: [Self.remnant(id: "r1", category: .caches, size: 2, safety: .safe)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(plan)
        let decoded = try decoder.decode(UninstallPlan.self, from: data)

        #expect(decoded.id == plan.id)
        #expect(decoded.app.bundleID == plan.app.bundleID)
        #expect(decoded.appBundle?.id == "bundle")
        #expect(decoded.remnants.count == 1)
        #expect(decoded.totalBytes == 3)
    }
}
