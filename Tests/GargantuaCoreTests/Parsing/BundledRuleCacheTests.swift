import Foundation
import Testing
@testable import GargantuaCore

@Suite("BundledRuleCache")
struct BundledRuleCacheTests {
    @Test("A directory is parsed once and served from the cache afterwards")
    func parsesOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledRuleCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.yaml")
        try """
        rules:
          - id: cached_rule
            name: Cached Rule
            paths:
              - ~/Library/Caches/Example
            safety: safe
            confidence: 90
            explanation: Test rule
            source:
              name: Test
            category: app_cache
        """.write(to: file, atomically: true, encoding: .utf8)

        let first = try BundledRuleCache.load(from: directory)
        try FileManager.default.removeItem(at: file)
        let second = try BundledRuleCache.load(from: directory)

        #expect(first.rules.map(\.id) == ["cached_rule"])
        #expect(second.rules.map(\.id) == ["cached_rule"])
    }
}
