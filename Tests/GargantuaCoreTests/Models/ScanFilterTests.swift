import Foundation
import Testing
@testable import GargantuaCore

private func makeFilterResult(
    id: String,
    path: String,
    size: Int64,
    safety: SafetyLevel,
    category: String,
    bundleID: String? = nil
) -> ScanResult {
    ScanResult(
        id: id,
        name: "Item \(id)",
        path: path,
        size: size,
        safety: safety,
        confidence: 90,
        explanation: "Test item",
        source: SourceAttribution(name: "Test", bundleID: bundleID),
        category: category
    )
}

@Suite("ScanFilterSet")
struct ScanFilterSetTests {
    @Test("allow-listed decoder drops injected fields and invalid safety")
    func allowListedDecoderDropsUnknownFields() throws {
        let json = """
        {
          "bundle_ids": ["com.apple.dt.Xcode"],
          "path_globs": ["*/Developer/Xcode/*"],
          "categories": ["dev_artifacts"],
          "min_size": 1024,
          "max_size": 4096,
          "safety": ["safe", "root"],
          "mutate_safety": "protected_",
          "shell": "rm -rf ~"
        }
        """

        let filter = try #require(ScanFilterSet.decodeAllowListed(from: json))

        #expect(filter.bundleIDs == ["com.apple.dt.Xcode"])
        #expect(filter.pathGlobs == ["*/Developer/Xcode/*"])
        #expect(filter.categories == ["dev_artifacts"])
        #expect(filter.minimumSize == 1024)
        #expect(filter.maximumSize == 4096)
        #expect(filter.safetyLevels == [.safe])
    }

    @Test("applying filter matches DSL fields")
    func appliesAllFields() {
        let filter = ScanFilterSet(
            bundleIDs: ["com.apple.dt.Xcode"],
            pathGlobs: ["*/Developer/Xcode/*"],
            categories: ["dev_artifacts"],
            minimumSize: 1_000,
            maximumSize: 5_000,
            safetyLevels: [.review]
        )
        let matching = makeFilterResult(
            id: "match",
            path: "/Users/me/Library/Developer/Xcode/DerivedData/a",
            size: 2_000,
            safety: .review,
            category: "dev_artifacts",
            bundleID: "com.apple.dt.Xcode"
        )
        let wrongBundle = makeFilterResult(
            id: "bundle",
            path: matching.path,
            size: 2_000,
            safety: .review,
            category: "dev_artifacts",
            bundleID: "com.example.App"
        )
        let wrongSafety = makeFilterResult(
            id: "safety",
            path: matching.path,
            size: 2_000,
            safety: .safe,
            category: "dev_artifacts",
            bundleID: "com.apple.dt.Xcode"
        )

        #expect(filter.apply(to: [wrongBundle, matching, wrongSafety]).map(\.id) == ["match"])
    }

    @Test("applying filter does not mutate ScanResult safety")
    func applyingFilterDoesNotMutateSafety() {
        let result = makeFilterResult(
            id: "xcode",
            path: "/Users/me/Library/Developer/Xcode/DerivedData/a",
            size: 2_000,
            safety: .review,
            category: "dev_artifacts",
            bundleID: "com.apple.dt.Xcode"
        )
        let filter = ScanFilterSet(categories: ["dev_artifacts"], safetyLevels: [.review])

        let filtered = filter.apply(to: [result])

        #expect(result.safety == .review)
        #expect(filtered.count == 1)
        #expect(filtered.first?.safety == .review)
    }
}
