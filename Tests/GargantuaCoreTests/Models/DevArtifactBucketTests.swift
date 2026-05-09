import Testing
import Foundation
@testable import GargantuaCore

@Suite("DevArtifactBucket derivation")
struct DevArtifactBucketTests {

    // MARK: helpers

    private static func makeResult(
        id: String = "test",
        category: String = "dev_artifacts",
        tags: [String] = [],
        sourceName: String = "Generic",
        path: String = "/tmp/x"
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: path,
            size: 1_000,
            safety: .safe,
            confidence: 90,
            explanation: "test",
            source: SourceAttribution(name: sourceName, bundleID: nil, verifySignature: false),
            category: category,
            tags: tags
        )
    }

    // MARK: ecosystem assignment

    @Test("Rule with jvm tag routes to JVM ecosystem bucket")
    func jvmTagRoutesToJVM() {
        let result = Self.makeResult(tags: ["developer", "jvm", "build_cache"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "jvm" }))
    }

    @Test("Rule with dotnet tag routes to .NET ecosystem bucket")
    func dotnetTagRoutesToDotNet() {
        let result = Self.makeResult(tags: ["developer", "dotnet"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "dotnet" }))
    }

    @Test("Rule with ruby tag routes to Ruby ecosystem bucket")
    func rubyTagRoutesToRuby() {
        let result = Self.makeResult(tags: ["developer", "ruby"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "ruby" }))
    }

    @Test("Rule with php tag routes to PHP ecosystem bucket")
    func phpTagRoutesToPHP() {
        let result = Self.makeResult(tags: ["developer", "php"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "php" }))
    }

    @Test("Low-frequency ecosystem tags fold into Other")
    func lowFrequencyTagsFoldIntoOther() {
        for tag in ["deno", "elixir", "haskell", "ocaml", "zig"] {
            let result = Self.makeResult(tags: ["developer", tag])
            let buckets = DevArtifactBucket.derive(from: result)
            #expect(
                buckets.contains(where: { $0.id == "other" }),
                "tag \(tag) should land in Other"
            )
        }
    }

    // MARK: cross-cutting accumulation

    @Test("build_cache tag adds the Build caches cross-cutting bucket alongside ecosystem")
    func buildCacheTagAddsCrossCutting() {
        let result = Self.makeResult(tags: ["developer", "rust", "build_cache"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "rust" }))
        #expect(buckets.contains(where: { $0.id == "build_cache" }))
    }

    @Test("Multiple cross-cutting tags accumulate without dropping any")
    func multipleCrossCuttingTagsAccumulate() {
        // Logs that are also under build_cache, with no ecosystem tag.
        let result = Self.makeResult(tags: ["developer", "logs", "build_cache"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "logs" }))
        #expect(buckets.contains(where: { $0.id == "build_cache" }))
    }

    @Test("ai/models tags both route to the AI/Models cross-cutting bucket without duplicating")
    func aiAndModelsCollapseToOneBucket() {
        let result = Self.makeResult(tags: ["developer", "ai", "models"])
        let buckets = DevArtifactBucket.derive(from: result)
        let aiCount = buckets.filter { $0.id == "ai_models" }.count
        #expect(aiCount == 1)
    }

    @Test("tests tag adds Tests cross-cutting bucket")
    func testsTagAddsTests() {
        let result = Self.makeResult(tags: ["developer", "tests"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "tests" }))
    }

    @Test("stale_versions tag adds Stale versions cross-cutting bucket")
    func staleVersionsTagAddsStaleVersions() {
        let result = Self.makeResult(tags: ["developer", "xcode", "stale_versions"], sourceName: "Xcode")
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "xcode" }))
        #expect(buckets.contains(where: { $0.id == "stale_versions" }))
    }

    // MARK: category fallback

    @Test("category=docker with no ecosystem tag falls back to Docker bucket")
    func dockerCategoryFallback() {
        let result = Self.makeResult(category: "docker", tags: ["developer", "containers"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "docker" }))
    }

    @Test("category=homebrew with no ecosystem tag falls back to Homebrew bucket")
    func homebrewCategoryFallback() {
        let result = Self.makeResult(category: "homebrew", tags: ["developer", "cache"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "homebrew" }))
        // cache is not a cross-cutting tag, so only the homebrew bucket should appear
        #expect(buckets.count == 1)
    }

    @Test("source.name=Xcode with build_cache tag routes to Xcode ecosystem + Build caches cross-cutting")
    func xcodeSourceFallback() {
        let result = Self.makeResult(
            category: "dev_artifacts",
            tags: ["developer", "build_cache"],
            sourceName: "Xcode"
        )
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "xcode" }))
        #expect(buckets.contains(where: { $0.id == "build_cache" }))
    }

    // MARK: Other fallback

    @Test("Result with no recognized tags or category lands in Other so it doesn't disappear")
    func unmappedTagsLandInOther() {
        let result = Self.makeResult(tags: ["developer", "dependencies"])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.contains(where: { $0.id == "other" }))
    }

    @Test("Empty tag list with generic dev_artifacts category lands in Other")
    func emptyTagsLandInOther() {
        let result = Self.makeResult(tags: [])
        let buckets = DevArtifactBucket.derive(from: result)
        #expect(buckets.map(\.id) == ["other"])
    }

    // MARK: catalog integrity

    @Test("Catalog contains all ecosystem and cross-cutting buckets the routing tables reference")
    func catalogCoversAllRoutedBuckets() {
        let allRoutedIDs = Set(DevArtifactBucketRouting.ecosystemTags.values)
            .union(DevArtifactBucketRouting.crossCuttingTags.values)
        let catalogIDs = Set(DevArtifactBucket.catalog.map(\.id))
        let missing = allRoutedIDs.subtracting(catalogIDs)
        #expect(missing.isEmpty, "Routing references buckets missing from catalog: \(missing)")
    }

    @Test("Each catalog id is unique")
    func catalogIDsAreUnique() {
        let ids = DevArtifactBucket.catalog.map(\.id)
        #expect(ids.count == Set(ids).count)
    }
}
