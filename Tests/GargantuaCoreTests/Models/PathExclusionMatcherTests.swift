import Foundation
import Testing
@testable import GargantuaCore

@Suite("PathExclusionMatcher")
struct PathExclusionMatcherTests {
    private let home = NSHomeDirectory()

    @Test("A literal exclusion covers the path, its descendants, and folders that contain it")
    func literalCoversPathDescendantsAndAncestors() {
        let matcher = PathExclusionMatcher(patterns: ["~/Library/Caches/com.acme.app"])
        #expect(matcher.excludes("\(home)/Library/Caches/com.acme.app"))
        #expect(matcher.excludes("\(home)/Library/Caches/com.acme.app/blobs/1"))
        #expect(matcher.excludes("\(home)/Library/Caches"))
        #expect(!matcher.excludes("\(home)/Library/Caches/com.acme.app2"))
        #expect(!matcher.excludes("\(home)/Library/Caches/com.other"))
    }

    @Test("A glob exclusion matches the path or any of its ancestors")
    func globMatchesPathOrAncestor() {
        let matcher = PathExclusionMatcher(patterns: ["*/node_modules"])
        #expect(matcher.excludes("/Users/x/dev/app/node_modules"))
        #expect(matcher.excludes("/Users/x/dev/app/node_modules/.cache/x"))
        #expect(!matcher.excludes("/Users/x/dev/app/build"))
    }

    @Test("Matching ignores case and trailing slashes")
    func ignoresCaseAndTrailingSlash() {
        let matcher = PathExclusionMatcher(patterns: ["~/Library/Caches/MyApp/"])
        #expect(matcher.excludes("\(home)/library/caches/myapp"))
    }

    @Test("Composite scans drop results that match an exclusion")
    func compositeFiltersResults() async throws {
        struct StaticAdapter: ScanAdapter {
            let results: [ScanResult]
            func scan(progress: ScanProgress?) async throws -> [ScanResult] { results }
        }
        let adapter = CompositeScanAdapter(
            primary: StaticAdapter(results: [result("/tmp/keep"), result("/tmp/skip/inner")]),
            bestEffort: [StaticAdapter(results: [result("/tmp/skip")])],
            exclusions: PathExclusionMatcher(patterns: ["/tmp/skip"])
        )

        let paths = try await adapter.scan(progress: nil).map(\.path)

        #expect(paths == ["/tmp/keep"])
    }

    private func result(_ path: String) -> ScanResult {
        ScanResult(
            id: path,
            name: (path as NSString).lastPathComponent,
            path: path,
            size: 1,
            safety: .safe,
            confidence: 90,
            explanation: "x",
            source: SourceAttribution(name: "test"),
            category: "system_cache"
        )
    }
}
