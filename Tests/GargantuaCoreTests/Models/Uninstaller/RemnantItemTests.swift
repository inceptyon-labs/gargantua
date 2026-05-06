import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantItem")
struct RemnantItemTests {

    static let sample = RemnantItem(
        id: "chrome_cache_001",
        appBundleID: "com.google.Chrome",
        category: .caches,
        path: "/Users/alice/Library/Caches/com.google.Chrome",
        size: 128_000_000,
        safety: .safe,
        confidence: 99,
        explanation: "Disposable cache data.",
        source: SourceAttribution(name: "Google Chrome", bundleID: "com.google.Chrome"),
        ruleID: "generic_caches",
        lastAccessed: Date(timeIntervalSince1970: 1_705_000_000),
        regenerates: true,
        tags: ["generic", "cache"]
    )

    @Test("All fields populated")
    func allFields() {
        let item = Self.sample
        #expect(item.id == "chrome_cache_001")
        #expect(item.appBundleID == "com.google.Chrome")
        #expect(item.category == .caches)
        #expect(item.path.hasSuffix("com.google.Chrome"))
        #expect(item.size == 128_000_000)
        #expect(item.safety == .safe)
        #expect(item.confidence == 99)
        #expect(item.source.bundleID == "com.google.Chrome")
        #expect(item.ruleID == "generic_caches")
        #expect(item.regenerates == true)
        #expect(item.tags == ["generic", "cache"])
    }

    @Test("Safety is mutable so the Trust Layer can reclassify")
    func safetyMutable() {
        var item = Self.sample
        item.safety = .review
        #expect(item.safety == .review)
    }

    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(RemnantItem.self, from: data)
        #expect(decoded.id == Self.sample.id)
        #expect(decoded.category == .caches)
        #expect(decoded.size == Self.sample.size)
        #expect(decoded.safety == .safe)
        #expect(decoded.ruleID == "generic_caches")
    }

    // MARK: - Receipt evidence

    private static func receiptItem(
        ruleID: String,
        tags: [String]
    ) -> RemnantItem {
        RemnantItem(
            id: "pkgutil-bom-com.docker.docker-0",
            appBundleID: "com.docker.docker",
            category: .other,
            path: "/Library/PrivilegedHelperTools/com.docker.vmnetd",
            size: 4_096,
            safety: .protected_,
            confidence: 95,
            explanation: "Owned by package com.docker.docker (v4.30.0) installed 2025-12-04. Shared system path — review carefully before removal.",
            source: SourceAttribution(name: "Docker", bundleID: "com.docker.docker"),
            ruleID: ruleID,
            tags: tags
        )
    }

    @Test("isReceiptEvidence true when tags contain pkgutil-bom")
    func receiptEvidenceTrueOnTag() {
        let item = Self.receiptItem(
            ruleID: "pkgutil-bom:com.docker.docker",
            tags: [ReceiptRemnantBuilder.receiptTag]
        )
        #expect(item.isReceiptEvidence == true)
    }

    @Test("isReceiptEvidence false on rule-derived rows")
    func receiptEvidenceFalseWithoutTag() {
        #expect(Self.sample.isReceiptEvidence == false)
        #expect(Self.sample.receiptPkgID == nil)
    }

    @Test("receiptPkgID extracts pkgID from ruleID prefix")
    func receiptPkgIDExtraction() {
        let item = Self.receiptItem(
            ruleID: "pkgutil-bom:com.docker.docker",
            tags: [ReceiptRemnantBuilder.receiptTag]
        )
        #expect(item.receiptPkgID == "com.docker.docker")
    }

    @Test("receiptPkgID nil when ruleID lacks expected prefix")
    func receiptPkgIDNilOnMalformedRule() {
        let item = Self.receiptItem(
            ruleID: "some-other-rule",
            tags: [ReceiptRemnantBuilder.receiptTag]
        )
        #expect(item.receiptPkgID == nil)
    }

    @Test("receiptPkgID nil when prefix is present but pkgID is empty")
    func receiptPkgIDNilOnEmptyID() {
        let item = Self.receiptItem(
            ruleID: "pkgutil-bom:",
            tags: [ReceiptRemnantBuilder.receiptTag]
        )
        #expect(item.receiptPkgID == nil)
    }
}
