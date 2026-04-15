import Testing
@testable import GargantuaCore

// MARK: - Test Helpers

private func makeScanResult(
    id: String = "test",
    safety: SafetyLevel,
    size: Int64 = 1000
) -> ScanResult {
    ScanResult(
        id: id,
        name: "Item \(id)",
        path: "/path/\(id)",
        size: size,
        safety: safety,
        confidence: 90,
        explanation: "Test item",
        source: SourceAttribution(name: "Test"),
        category: "test"
    )
}

// MARK: - ScanBucket Grouping

@Suite("ScanBucket")
struct ScanBucketTests {
    @Test("Group returns three buckets in order: safe, review, protected")
    func groupOrder() {
        let results = [
            makeScanResult(id: "r1", safety: .review),
            makeScanResult(id: "s1", safety: .safe),
            makeScanResult(id: "p1", safety: .protected_),
        ]
        let buckets = ScanBucket.group(results)
        #expect(buckets.count == 3)
        #expect(buckets[0].id == .safe)
        #expect(buckets[1].id == .review)
        #expect(buckets[2].id == .protected_)
    }

    @Test("Group includes empty buckets when no items for a level")
    func emptyBuckets() {
        let results = [makeScanResult(id: "s1", safety: .safe)]
        let buckets = ScanBucket.group(results)
        #expect(buckets.count == 3)
        #expect(buckets[0].count == 1)
        #expect(buckets[1].items.isEmpty)
        #expect(buckets[2].items.isEmpty)
    }

    @Test("Group with empty input returns three empty buckets")
    func emptyInput() {
        let buckets = ScanBucket.group([])
        #expect(buckets.count == 3)
        #expect(buckets.allSatisfy { $0.items.isEmpty })
    }

    @Test("Count matches number of items")
    func count() {
        let results = [
            makeScanResult(id: "s1", safety: .safe),
            makeScanResult(id: "s2", safety: .safe),
            makeScanResult(id: "r1", safety: .review),
        ]
        let buckets = ScanBucket.group(results)
        #expect(buckets[0].count == 2)  // safe
        #expect(buckets[1].count == 1)  // review
    }

    @Test("Total size sums item sizes correctly")
    func totalSize() {
        let results = [
            makeScanResult(id: "s1", safety: .safe, size: 1000),
            makeScanResult(id: "s2", safety: .safe, size: 2500),
        ]
        let buckets = ScanBucket.group(results)
        #expect(buckets[0].totalSize == 3500)
    }

    @Test("Total size is zero for empty bucket")
    func emptyTotalSize() {
        let buckets = ScanBucket.group([])
        #expect(buckets[0].totalSize == 0)
    }

    @Test("Titles match expected labels")
    func titles() {
        let buckets = ScanBucket.group([])
        #expect(buckets[0].title == "Safe to Clean")
        #expect(buckets[1].title == "Review Required")
        #expect(buckets[2].title == "Protected")
    }

    @Test("Items within each bucket match their safety level")
    func itemSafetyMatches() {
        let results = [
            makeScanResult(id: "s1", safety: .safe),
            makeScanResult(id: "r1", safety: .review),
            makeScanResult(id: "p1", safety: .protected_),
        ]
        let buckets = ScanBucket.group(results)
        for bucket in buckets {
            for item in bucket.items {
                #expect(item.safety == bucket.id)
            }
        }
    }

    @Test("Large size values do not overflow")
    func largeSizes() {
        let results = [
            makeScanResult(id: "s1", safety: .safe, size: Int64.max / 2),
            makeScanResult(id: "s2", safety: .safe, size: Int64.max / 2),
        ]
        let buckets = ScanBucket.group(results)
        // Should not crash — overflow would trap in debug
        #expect(buckets[0].totalSize == Int64.max / 2 + Int64.max / 2)
    }
}
