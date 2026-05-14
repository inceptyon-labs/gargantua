import Testing
import Foundation
@testable import GargantuaCore

@Suite("LocalOrganizerProposer heuristics")
struct LocalOrganizerProposerTests {

    // MARK: helpers

    /// Build a throwaway directory in the temp tree. Caller is responsible
    /// for populating + removing it.
    private static func makeScratchFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("organizer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func touch(
        _ name: String,
        in folder: URL,
        modified: Date = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    ) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func cleanup(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: extension grouping

    @Test("Two PDFs are grouped into a Documents plan")
    func pdfsGroupedAsDocuments() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        _ = try Self.touch("a.pdf", in: root)
        _ = try Self.touch("b.pdf", in: root)

        let proposer = LocalOrganizerProposer()
        let proposal = try proposer.propose(sourceFolder: root)

        #expect(proposal.plans.count == 1)
        #expect(proposal.plans.first?.name == "Documents")
        #expect(proposal.plans.first?.moves.count == 2)
    }

    @Test("Mixed images and videos produce two plans")
    func imagesAndVideosSeparated() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        _ = try Self.touch("photo1.jpg", in: root)
        _ = try Self.touch("photo2.png", in: root)
        _ = try Self.touch("clip1.mp4", in: root)
        _ = try Self.touch("clip2.mov", in: root)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)

        let names = Set(proposal.plans.map(\.name))
        #expect(names == ["Images", "Videos"])
    }

    @Test("Screenshot-prefixed PNG goes to Screenshots, not Images")
    func screenshotsBeatImages() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        _ = try Self.touch("Screenshot 2025-01-01 at 10.00.00 AM.png", in: root)
        _ = try Self.touch("Screen Shot 2024-12-31 at 11.00.00 PM.png", in: root)
        _ = try Self.touch("regular-photo.png", in: root)
        _ = try Self.touch("another-photo.png", in: root)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)

        let names = Set(proposal.plans.map(\.name))
        #expect(names.contains("Screenshots"))
        #expect(names.contains("Images"))

        let shotPlan = proposal.plans.first { $0.name == "Screenshots" }
        #expect(shotPlan?.moves.count == 2)
    }

    // MARK: skip rules

    @Test("Single-file categories produce no plan (cluster threshold)")
    func singleFileDropsPlan() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        _ = try Self.touch("lonely.pdf", in: root)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)
        #expect(proposal.plans.isEmpty)
    }

    @Test("Recent uncategorized files are skipped (no year-bin churn on active work)")
    func recentUncategorizedSkipped() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        // .xyz isn't in the extension map → falls into year-bin path,
        // but only if older than the cutoff. Touched right now: skip.
        _ = try Self.touch("a.xyz", in: root, modified: Date())
        _ = try Self.touch("b.xyz", in: root, modified: Date())

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)
        #expect(proposal.plans.isEmpty)
    }

    @Test("Old uncategorized files bin into year folder")
    func oldFilesBinByYear() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        let oldDate = Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2022, month: 6, day: 15))!
        _ = try Self.touch("legacy1.xyz", in: root, modified: oldDate)
        _ = try Self.touch("legacy2.xyz", in: root, modified: oldDate)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)
        #expect(proposal.plans.first?.name == "2022")
    }

    @Test("Hidden files are skipped")
    func hiddenFilesSkipped() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        _ = try Self.touch(".DS_Store", in: root)
        _ = try Self.touch(".secret.pdf", in: root)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)
        #expect(proposal.plans.isEmpty)
    }

    @Test("Subfolders are not traversed and not moved")
    func subfoldersIgnored() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        let nested = root.appendingPathComponent("AlreadyOrganized", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try Self.touch("inside1.pdf", in: nested)
        _ = try Self.touch("inside2.pdf", in: nested)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)
        #expect(proposal.plans.isEmpty)
    }

    @Test("Proposal passes validate() — no out-of-root or root-flat moves")
    func proposalIsValid() throws {
        let root = try Self.makeScratchFolder()
        defer { Self.cleanup(root) }
        _ = try Self.touch("a.pdf", in: root)
        _ = try Self.touch("b.pdf", in: root)
        _ = try Self.touch("c.jpg", in: root)
        _ = try Self.touch("d.jpg", in: root)

        let proposal = try LocalOrganizerProposer().propose(sourceFolder: root)
        try proposal.validate() // would throw if invalid
        #expect(proposal.backend == .local)
    }
}
