import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP scan session cache")
struct MCPScanSessionCacheTests {

    private static func makeResult(id: String, size: Int64 = 1_024, safety: SafetyLevel = .safe) -> ScanResult {
        ScanResult(
            id: id,
            name: "name-\(id)",
            path: "/tmp/\(id)",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "test",
            source: SourceAttribution(name: "TestApp"),
            category: "browser_cache"
        )
    }

    @Test("lookup returns nil for a fresh cache")
    func freshCacheReturnsNil() {
        let cache = MCPScanSessionCache()
        #expect(cache.lookup(id: "anything") == nil)
        #expect(cache.isEmpty)
    }

    @Test("replace populates the cache keyed by id")
    func replacePopulates() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [
            Self.makeResult(id: "a", size: 100),
            Self.makeResult(id: "b", size: 200),
        ])
        #expect(cache.count == 2)
        #expect(cache.lookup(id: "a")?.size == 100)
        #expect(cache.lookup(id: "b")?.size == 200)
    }

    @Test("replace is last-scan-wins: prior entries are dropped")
    func replaceReplacesPriorEntries() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [Self.makeResult(id: "old")])
        cache.replace(with: [Self.makeResult(id: "new")])
        #expect(cache.lookup(id: "old") == nil)
        #expect(cache.lookup(id: "new") != nil)
        #expect(cache.count == 1)
    }

    @Test("replace with empty array clears the cache")
    func replaceWithEmptyClears() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [Self.makeResult(id: "x")])
        cache.replace(with: [])
        #expect(cache.isEmpty)
        #expect(cache.lookup(id: "x") == nil)
    }

    @Test("lookupAll partitions known and unknown ids, preserving order")
    func lookupAllPartitions() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [
            Self.makeResult(id: "a"),
            Self.makeResult(id: "b"),
            Self.makeResult(id: "c"),
        ])
        let (found, unknown) = cache.lookupAll(ids: ["a", "missing", "c", "also-missing"])
        #expect(found.map(\.id) == ["a", "c"])
        #expect(unknown == ["missing", "also-missing"])
    }

    @Test("lookupAll with all-known ids returns no unknowns")
    func lookupAllAllKnown() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [Self.makeResult(id: "a"), Self.makeResult(id: "b")])
        let (found, unknown) = cache.lookupAll(ids: ["b", "a"])
        #expect(found.map(\.id) == ["b", "a"])
        #expect(unknown.isEmpty)
    }

    @Test("clear empties the cache")
    func clearEmpties() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [Self.makeResult(id: "a")])
        cache.clear()
        #expect(cache.isEmpty)
    }

    @Test("duplicate ids within a replace resolve to the last occurrence")
    func duplicateIdsLastWins() {
        let cache = MCPScanSessionCache()
        cache.replace(with: [
            Self.makeResult(id: "dup", size: 100),
            Self.makeResult(id: "dup", size: 999),
        ])
        #expect(cache.count == 1)
        #expect(cache.lookup(id: "dup")?.size == 999)
    }
}
