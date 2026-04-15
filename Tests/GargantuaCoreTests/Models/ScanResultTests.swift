import Testing
import Foundation
@testable import GargantuaCore

@Suite("ScanResult")
struct ScanResultTests {
    static let sampleResult = ScanResult(
        id: "chrome_cache_001",
        name: "Chrome Browser Cache",
        path: "~/Library/Caches/Google/Chrome",
        size: 10_500_000_000,
        safety: .safe,
        confidence: 99,
        explanation: "Browser cache files. Regenerated automatically when you browse.",
        source: SourceAttribution(
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            verifySignature: true
        ),
        lastAccessed: Date(timeIntervalSince1970: 1_700_000_000),
        category: "browser_cache",
        tags: ["cache", "browser", "chromium"],
        regenerates: true
    )

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(Self.sampleResult)
        let decoded = try decoder.decode(ScanResult.self, from: data)

        #expect(decoded.id == "chrome_cache_001")
        #expect(decoded.name == "Chrome Browser Cache")
        #expect(decoded.path == "~/Library/Caches/Google/Chrome")
        #expect(decoded.size == 10_500_000_000)
        #expect(decoded.safety == .safe)
        #expect(decoded.confidence == 99)
        #expect(decoded.explanation == "Browser cache files. Regenerated automatically when you browse.")
        #expect(decoded.source.name == "Google Chrome")
        #expect(decoded.source.bundleID == "com.google.Chrome")
        #expect(decoded.source.verifySignature == true)
        #expect(decoded.category == "browser_cache")
        #expect(decoded.tags == ["cache", "browser", "chromium"])
        #expect(decoded.regenerates == true)
    }

    @Test("Default values for optional fields")
    func defaults() {
        let minimal = ScanResult(
            id: "test",
            name: "Test",
            path: "/tmp/test",
            size: 0,
            safety: .review,
            confidence: 50,
            explanation: "Test item.",
            source: SourceAttribution(name: "Unknown"),
            category: "test"
        )

        #expect(minimal.lastAccessed == nil)
        #expect(minimal.tags.isEmpty)
        #expect(minimal.regenerates == false)
        #expect(minimal.regenerateCommand == nil)
    }
}
