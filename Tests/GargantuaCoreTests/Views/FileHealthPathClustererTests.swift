import Foundation
import Testing
@testable import GargantuaCore

private let testHome = URL(fileURLWithPath: "/Users/jason")

private func makeFinding(path: String, size: Int64 = 1_024) -> ScanResult {
    ScanResult(
        id: path,
        name: (path as NSString).lastPathComponent,
        path: path,
        size: size,
        safety: .review,
        confidence: 60,
        explanation: "",
        source: SourceAttribution(name: "Czkawka"),
        category: "broken_files",
        tags: []
    )
}

@Suite("FileHealthPathClusterer")
struct FileHealthPathClustererTests {

    @Test("Empty input produces no clusters")
    func emptyInput() {
        let clusters = FileHealthPathClusterer.clusters(from: [], homeDirectory: testHome)
        #expect(clusters.isEmpty)
    }

    @Test("Findings under home group by their first three components")
    func groupsByThreeComponentsBelowHome() {
        let findings = [
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/session-a/foo.png"),
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/session-b/bar.png"),
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/session-c/baz.png"),
            makeFinding(path: "/Users/jason/Development/inceptyon/build/ios/Debug/qux.png"),
            makeFinding(path: "/Users/jason/Development/inceptyon/build/android/Release/zip.png"),
            makeFinding(path: "/Users/jason/Development/chipshot/apps/web/test-results/a.png"),
            makeFinding(path: "/Users/jason/Development/chipshot/apps/web/test-results/b.png"),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)

        #expect(clusters.count == 3)
        #expect(clusters[0].id == "~/Development/dreamheist/builds/")
        #expect(clusters[0].count == 3)
        #expect(clusters[0].displayLabel == "dreamheist/builds")
        #expect(clusters[1].id == "~/Development/inceptyon/build/")
        #expect(clusters[1].count == 2)
        #expect(clusters[2].id == "~/Development/chipshot/apps/")
        #expect(clusters[2].count == 2)
    }

    @Test("Singletons are excluded so chips only surface bulk wins")
    func singletonsAreExcluded() {
        let findings = [
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/a"),
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/b"),
            makeFinding(path: "/Users/jason/Documents/Notes/once.txt"),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)

        #expect(clusters.count == 1)
        #expect(clusters[0].id == "~/Development/dreamheist/builds/")
    }

    @Test("Tie-breaks by first-seen order so chip ordering is stable")
    func stableOrderingOnTie() {
        let findings = [
            makeFinding(path: "/Users/jason/A/aa/aaa/x"),
            makeFinding(path: "/Users/jason/A/aa/aaa/y"),
            makeFinding(path: "/Users/jason/B/bb/bbb/x"),
            makeFinding(path: "/Users/jason/B/bb/bbb/y"),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)

        #expect(clusters.map(\.id) == ["~/A/aa/aaa/", "~/B/bb/bbb/"])
    }

    @Test("Total size aggregates per cluster and saturates on overflow")
    func totalSizeAggregatesAndSaturates() {
        let bigA = Int64.max - 100
        let findings = [
            makeFinding(path: "/Users/jason/X/y/z/a", size: bigA),
            makeFinding(path: "/Users/jason/X/y/z/b", size: 500),
            makeFinding(path: "/Users/jason/X/y/z/c", size: 1_000),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)

        #expect(clusters.count == 1)
        #expect(clusters[0].totalSize == Int64.max)
    }

    @Test("Limit caps the chip count at the requested top-N")
    func limitCaps() {
        // Six clusters of two findings each → expect only the first 4 with limit 4.
        let findings: [ScanResult] = (0 ..< 6).flatMap { idx -> [ScanResult] in
            [
                makeFinding(path: "/Users/jason/proj/dir\(idx)/sub/a"),
                makeFinding(path: "/Users/jason/proj/dir\(idx)/sub/b"),
            ]
        }
        let clusters = FileHealthPathClusterer.clusters(
            from: findings,
            homeDirectory: testHome,
            limit: 4
        )

        #expect(clusters.count == 4)
    }

    @Test("Paths outside home use absolute-path prefixes")
    func pathsOutsideHome() {
        let findings = [
            makeFinding(path: "/var/log/foo/a.log"),
            makeFinding(path: "/var/log/foo/b.log"),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)

        #expect(clusters.count == 1)
        #expect(clusters[0].id == "/var/log/foo/")
        #expect(clusters[0].displayLabel == "log/foo")
    }

    @Test("Paths shallower than depth are skipped")
    func shallowPathsSkipped() {
        // Two-component path can't form a 3-deep cluster.
        let findings = [
            makeFinding(path: "/Users/jason/topfile.txt"),
            makeFinding(path: "/Users/jason/another.txt"),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)

        #expect(clusters.isEmpty)
    }

    @Test("Display label falls back to the full prefix when fewer than two components")
    func displayLabelFallback() {
        // Single-component absolute path.
        let label = FileHealthPathClusterer.displayLabel(for: "/var/")
        #expect(label == "var")
    }

    @Test("samplesByCluster returns up to N matching paths per cluster, scoped to that cluster")
    func samplesByClusterReturnsMatchingPaths() {
        let findings = [
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/a/foo.png"),
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/b/bar.png"),
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/c/baz.png"),
            makeFinding(path: "/Users/jason/Development/dreamheist/builds/d/qux.png"),
            makeFinding(path: "/Users/jason/Development/inceptyon/build/ios/foo.png"),
            makeFinding(path: "/Users/jason/Development/inceptyon/build/android/bar.png"),
        ]
        let clusters = FileHealthPathClusterer.clusters(from: findings, homeDirectory: testHome)
        let samples = FileHealthPathClusterer.samplesByCluster(
            clusters,
            findings: findings,
            homeDirectory: testHome,
            limit: 3
        )

        let dreamheist = samples["~/Development/dreamheist/builds/"] ?? []
        let inceptyon = samples["~/Development/inceptyon/build/"] ?? []

        #expect(dreamheist.count == 3, "limit should cap matches at 3")
        #expect(dreamheist.allSatisfy { $0.contains("/dreamheist/builds/") })
        #expect(inceptyon.count == 2)
        #expect(inceptyon.allSatisfy { $0.contains("/inceptyon/build/") })
    }

    @Test("samplesByCluster returns empty map when no findings match any cluster")
    func samplesByClusterEmptyMap() {
        let clusters = FileHealthPathClusterer.clusters(from: [], homeDirectory: testHome)
        let samples = FileHealthPathClusterer.samplesByCluster(clusters, findings: [], homeDirectory: testHome)
        #expect(samples.isEmpty)
    }
}
