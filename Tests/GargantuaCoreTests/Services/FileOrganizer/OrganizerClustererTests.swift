import Testing
import Foundation
@testable import GargantuaCore

@Suite("OrganizerClusterer")
struct OrganizerClustererTests {

    private static func item(
        name: String,
        size: Int64 = 100,
        modified: Date = Date(timeIntervalSince1970: 1)
    ) -> CloudOrganizerProposer.FolderListingItem {
        CloudOrganizerProposer.FolderListingItem(
            id: UUID().uuidString,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            sizeBytes: size,
            modifiedAt: modified
        )
    }

    @Test("PDFs and images bucket into separate clusters")
    func separatesByExtensionCategory() {
        let clusters = OrganizerClusterer.cluster([
            Self.item(name: "a.pdf"),
            Self.item(name: "b.pdf"),
            Self.item(name: "c.jpg"),
        ])
        let labels = clusters.map(\.inferredType).sorted()
        #expect(labels == ["documents", "images"])
    }

    @Test("Screenshot-prefixed PNGs separate from regular images")
    func screenshotSplit() {
        let clusters = OrganizerClusterer.cluster([
            Self.item(name: "Screenshot 2025-01-01.png"),
            Self.item(name: "Screen Shot 2024-12-31.png"),
            Self.item(name: "vacation.jpg"),
            Self.item(name: "headshot.png"),
        ])
        let types = Set(clusters.map(\.inferredType))
        #expect(types.contains("screenshots"))
        #expect(types.contains("images"))
        let screenshotCluster = clusters.first { $0.inferredType == "screenshots" }
        #expect(screenshotCluster?.items.count == 2)
    }

    @Test("Cluster IDs are deterministic C1, C2, … in size-descending order")
    func clusterIDsAssignedByByteSize() {
        // documents = 1000 bytes total, images = 100 bytes total →
        // documents cluster gets C1, images gets C2.
        let clusters = OrganizerClusterer.cluster([
            Self.item(name: "big.pdf", size: 500),
            Self.item(name: "big2.pdf", size: 500),
            Self.item(name: "tiny.jpg", size: 100),
        ])
        #expect(clusters.first?.inferredType == "documents")
        #expect(clusters.first?.id == "C1")
        #expect(clusters.last?.inferredType == "images")
        #expect(clusters.last?.id == "C2")
    }

    @Test("Unknown extensions bucket into ext:* clusters per extension")
    func unknownExtensionsBucketSeparately() {
        let clusters = OrganizerClusterer.cluster([
            Self.item(name: "log1.log"),
            Self.item(name: "log2.log"),
            Self.item(name: "data.torrent"),
            Self.item(name: "data2.torrent"),
        ])
        let types = Set(clusters.map(\.inferredType))
        #expect(types == ["ext:log", "ext:torrent"])
    }

    @Test("Files without extension bucket into no-extension cluster")
    func noExtensionCluster() {
        let clusters = OrganizerClusterer.cluster([
            Self.item(name: "Makefile"),
            Self.item(name: "README"),
        ])
        #expect(clusters.first?.inferredType == "no-extension")
    }

    @Test("Sample names are oldest-first, deterministic")
    func sampleNamesAreDeterministic() {
        let items = (1...5).map { index in
            Self.item(
                name: "file-\(index).pdf",
                modified: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let clusters = OrganizerClusterer.cluster(items)
        let samples = clusters.first?.sampleNames(limit: 3)
        // Index 5 has the oldest modified date.
        #expect(samples == ["file-5.pdf", "file-4.pdf", "file-3.pdf"])
    }

    @Test("Total bytes sums correctly across cluster")
    func totalBytesSums() {
        let clusters = OrganizerClusterer.cluster([
            Self.item(name: "a.pdf", size: 100),
            Self.item(name: "b.pdf", size: 250),
            Self.item(name: "c.pdf", size: 75),
        ])
        #expect(clusters.first?.totalBytes == 425)
    }

    @Test("Empty input yields no clusters")
    func emptyInput() {
        #expect(OrganizerClusterer.cluster([]).isEmpty)
    }
}
