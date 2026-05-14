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

    // MARK: - Prompt

    @Test("Prompt includes folder name and each item's id + name")
    func promptContainsListing() throws {
        let items = [
            Self.listingItem(id: "ID-A", name: "alpha.pdf"),
            Self.listingItem(id: "ID-B", name: "beta.pdf"),
        ]
        let prompt = try CloudOrganizerProposer.buildPrompt(folderName: "Downloads", items: items)

        #expect(prompt.contains("Folder: Downloads"))
        #expect(prompt.contains("ID-A"))
        #expect(prompt.contains("ID-B"))
        #expect(prompt.contains("alpha.pdf"))
        #expect(prompt.contains("beta.pdf"))
        // Filenames travel as metadata but absolute paths must not.
        #expect(!prompt.contains("/Users/test"))
    }

    @Test("Prompt instruction prefix is included verbatim")
    func promptIncludesInstructions() throws {
        let prompt = try CloudOrganizerProposer.buildPrompt(folderName: "Desktop", items: [])
        #expect(prompt.contains(CloudOrganizerProposer.instructionPrefix))
    }

    // MARK: - Parsing happy path

    @Test("Valid model response reassembles into an OrganizationProposal")
    func parseHappyPath() throws {
        let items = [
            Self.listingItem(id: "ID-A", name: "alpha.pdf"),
            Self.listingItem(id: "ID-B", name: "beta.pdf"),
        ]
        let response = #"{"plans":[{"name":"Documents","reasoning":"Both PDFs.","item_ids":["ID-A","ID-B"]}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            listing: items
        )

        #expect(proposal.backend == .cloud)
        #expect(proposal.plans.count == 1)
        #expect(proposal.plans[0].name == "Documents")
        #expect(proposal.plans[0].moves.count == 2)
        #expect(proposal.plans[0].moves.map(\.sourceURL.lastPathComponent) == ["alpha.pdf", "beta.pdf"])
    }

    // MARK: - Parsing safety

    @Test("Model item_id not in the listing is silently dropped")
    func parseDropsUnknownID() throws {
        let items = [
            Self.listingItem(id: "ID-A", name: "alpha.pdf"),
            Self.listingItem(id: "ID-B", name: "beta.pdf"),
        ]
        // Includes "ID-X" which is fabricated by the model.
        let response = #"{"plans":[{"name":"Documents","reasoning":"x","item_ids":["ID-A","ID-X","ID-B"]}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            listing: items
        )

        #expect(proposal.plans[0].moves.count == 2)
    }

    @Test("Plan with <2 valid members is dropped")
    func parseDropsSinglePlan() throws {
        let items = [
            Self.listingItem(id: "ID-A", name: "alpha.pdf"),
        ]
        let response = #"{"plans":[{"name":"Documents","reasoning":"x","item_ids":["ID-A"]}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            listing: items
        )

        #expect(proposal.plans.isEmpty)
    }

    @Test("Plan name with path separator is dropped (not raised)")
    func parseDropsBadName() throws {
        let items = [
            Self.listingItem(id: "ID-A", name: "alpha.pdf"),
            Self.listingItem(id: "ID-B", name: "beta.pdf"),
        ]
        // "A/B" would fail OrganizationProposal.validate(); we drop it
        // before validation so a single bad plan doesn't fail the lot.
        let response = #"{"plans":[{"name":"A/B","reasoning":"x","item_ids":["ID-A","ID-B"]}]}"#

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            listing: items
        )

        #expect(proposal.plans.isEmpty)
    }

    @Test("Garbage response throws unparseableResponse")
    func parseGarbageThrows() {
        #expect(throws: CloudOrganizerProposerError.unparseableResponse) {
            try CloudOrganizerProposer.parseResponse(
                text: "completely not json",
                sourceFolder: Self.root,
                listing: []
            )
        }
    }

    @Test("Reassembled proposal passes validate() — moves stay inside the root")
    func parseProducesValidProposal() throws {
        let items = [
            Self.listingItem(id: "ID-A", name: "alpha.pdf"),
            Self.listingItem(id: "ID-B", name: "beta.pdf"),
            Self.listingItem(id: "ID-C", name: "screenshot.png"),
            Self.listingItem(id: "ID-D", name: "another.png"),
        ]
        let response = """
        {"plans":[
          {"name":"Documents","reasoning":"x","item_ids":["ID-A","ID-B"]},
          {"name":"Images","reasoning":"y","item_ids":["ID-C","ID-D"]}
        ]}
        """

        let proposal = try CloudOrganizerProposer.parseResponse(
            text: response,
            sourceFolder: Self.root,
            listing: items
        )

        try proposal.validate()
        #expect(proposal.plans.count == 2)
    }

    // MARK: - Folder listing (light I/O test)

    @Test("listFolder truncates to maxListingSize, keeping oldest first")
    func listFolderTruncates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cloud-trunc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 250 files, modification dates spread across days — the oldest
        // 200 should survive truncation, the newest 50 should be dropped.
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
        // First item is the oldest one we wrote (index 0).
        #expect(items.first?.name == "file-0.bin")
        // Last item that survived is index 199 (since 200..249 were dropped).
        #expect(items.last?.name == "file-199.bin")
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
