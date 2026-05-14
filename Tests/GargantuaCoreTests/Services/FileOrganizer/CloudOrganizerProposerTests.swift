import Testing
import Foundation
@testable import GargantuaCore

@Suite("CloudOrganizerProposer prompt + parsing")
struct CloudOrganizerProposerTests {

    private static let root = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

    private static func listingItem(id: String, name: String) -> CloudOrganizerProposer.FolderListingItem {
        CloudOrganizerProposer.FolderListingItem(
            id: id,
            url: Self.root.appendingPathComponent(name),
            name: name,
            sizeBytes: 1234,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func cluster(
        id: String,
        items: [CloudOrganizerProposer.FolderListingItem],
        inferredType: String = "documents"
    ) -> OrganizerCluster {
        OrganizerCluster(id: id, items: items, inferredType: inferredType)
    }

    // MARK: - Prompt

    @Test("Prompt includes folder name and each cluster's id, count, and sample names")
    func promptContainsClusters() {
        let clusters = [
            Self.cluster(id: "C1", items: [
                Self.listingItem(id: "X-1", name: "alpha.pdf"),
                Self.listingItem(id: "X-2", name: "beta.pdf"),
            ]),
            Self.cluster(id: "C2", items: [
                Self.listingItem(id: "Y-1", name: "photo.jpg"),
                Self.listingItem(id: "Y-2", name: "photo2.png"),
            ], inferredType: "images"),
        ]
        let prompt = CloudOrganizerProposer.buildPrompt(folderName: "Downloads", clusters: clusters)

        #expect(prompt.contains("Folder: Downloads"))
        #expect(prompt.contains("Cluster C1"))
        #expect(prompt.contains("Cluster C2"))
        #expect(prompt.contains("alpha.pdf"))
        #expect(prompt.contains("photo.jpg"))
        #expect(prompt.contains("inferred type: documents"))
        #expect(prompt.contains("inferred type: images"))
        // Absolute paths must not leak.
        #expect(!prompt.contains("/Users/test"))
    }

    @Test("Prompt instruction prefix is included verbatim")
    func promptIncludesInstructions() {
        let prompt = CloudOrganizerProposer.buildPrompt(folderName: "Desktop", clusters: [])
        #expect(prompt.contains(CloudOrganizerProposer.instructionPrefix))
    }

    @Test("Big cluster shows sample names + '[N more]' tail")
    func promptShowsRemainder() {
        let manyItems = (1...25).map { Self.listingItem(id: "X-\($0)", name: "file-\($0).pdf") }
        let prompt = CloudOrganizerProposer.buildPrompt(
            folderName: "Downloads",
            clusters: [Self.cluster(id: "C1", items: manyItems)]
        )
        #expect(prompt.contains("[15 more]"))
    }

    // MARK: - Parsing happy path

    @Test("Valid model response reassembles into an OrganizationProposal")
    func parseHappyPath() throws {
        let clusterItems = [
            Self.listingItem(id: "X-1", name: "alpha.pdf"),
            Self.listingItem(id: "X-2", name: "beta.pdf"),
        ]
        let clusters = [Self.cluster(id: "C1", items: clusterItems)]
        let response = #"{"plans":[{"cluster_id":"C1","name":"Receipts","reasoning":"PDFs"}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            clusters: clusters
        )

        #expect(proposal.backend == .cloud)
        #expect(proposal.plans.count == 1)
        #expect(proposal.plans[0].name == "Receipts")
        #expect(proposal.plans[0].moves.count == 2)
        #expect(proposal.plans[0].moves.map(\.sourceURL.lastPathComponent) == ["alpha.pdf", "beta.pdf"])
    }

    // MARK: - Parsing safety

    @Test("Cluster_id not in the supplied clusters is silently dropped")
    func parseDropsUnknownCluster() throws {
        let items = [
            Self.listingItem(id: "X-1", name: "alpha.pdf"),
            Self.listingItem(id: "X-2", name: "beta.pdf"),
        ]
        let clusters = [Self.cluster(id: "C1", items: items)]
        let response = """
        {"plans":[
          {"cluster_id":"C1","name":"Documents","reasoning":"x"},
          {"cluster_id":"C99","name":"Fabricated","reasoning":"y"}
        ]}
        """

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            clusters: clusters
        )
        #expect(proposal.plans.count == 1)
        #expect(proposal.plans[0].name == "Documents")
    }

    @Test("Cluster with <2 items skipped (single-file plans are noise)")
    func parseDropsSinglePlan() throws {
        let items = [Self.listingItem(id: "X-1", name: "lonely.pdf")]
        let clusters = [Self.cluster(id: "C1", items: items)]
        let response = #"{"plans":[{"cluster_id":"C1","name":"Documents","reasoning":"x"}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            clusters: clusters
        )
        #expect(proposal.plans.isEmpty)
    }

    @Test("Plan name with path separator is dropped (not raised)")
    func parseDropsBadName() throws {
        let items = [
            Self.listingItem(id: "X-1", name: "alpha.pdf"),
            Self.listingItem(id: "X-2", name: "beta.pdf"),
        ]
        let clusters = [Self.cluster(id: "C1", items: items)]
        let response = #"{"plans":[{"cluster_id":"C1","name":"A/B","reasoning":"x"}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            clusters: clusters
        )
        #expect(proposal.plans.isEmpty)
    }

    @Test("Garbage response throws unparseableResponse")
    func parseGarbageThrows() {
        #expect(throws: CloudOrganizerProposerError.unparseableResponse) {
            try CloudOrganizerProposer.parseResponse(
                text: "completely not json",
                sourceFolder: Self.root,
                clusters: []
            )
        }
    }

    @Test("Reassembled proposal passes validate()")
    func parseProducesValidProposal() throws {
        let clusters = [
            Self.cluster(id: "C1", items: [
                Self.listingItem(id: "X-1", name: "alpha.pdf"),
                Self.listingItem(id: "X-2", name: "beta.pdf"),
            ]),
            Self.cluster(id: "C2", items: [
                Self.listingItem(id: "Y-1", name: "shot.png"),
                Self.listingItem(id: "Y-2", name: "another.png"),
            ], inferredType: "images"),
        ]
        let response = """
        {"plans":[
          {"cluster_id":"C1","name":"Documents","reasoning":"x"},
          {"cluster_id":"C2","name":"Images","reasoning":"y"}
        ]}
        """
        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            clusters: clusters
        )
        try proposal.validate()
        #expect(proposal.plans.count == 2)
    }

    // MARK: - Folder listing

    @Test("listFolder truncates to maxListingSize, keeping oldest first")
    func listFolderTruncates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cloud-trunc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let count = CloudOrganizerProposer.maxListingSize + 50
        for index in 0..<count {
            let url = dir.appendingPathComponent("file-\(index).bin")
            try Data("x".utf8).write(to: url)
            let modified = Date(timeIntervalSince1970: TimeInterval(1_000_000_000 + index * 86_400))
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }

        let items = try CloudOrganizerProposer.listFolder(at: dir)
        #expect(items.count == CloudOrganizerProposer.maxListingSize)
        #expect(items.first?.name == "file-0.bin")
    }

    @Test("listFolder returns top-level non-hidden files only")
    func listFolderSkipsHiddenAndDirs() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cloud-org-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("x".utf8).write(to: dir.appendingPathComponent("real.pdf"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden.pdf"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("subdir"),
            withIntermediateDirectories: true
        )

        let items = try CloudOrganizerProposer.listFolder(at: dir)
        #expect(items.count == 1)
        #expect(items.first?.name == "real.pdf")
    }
}
