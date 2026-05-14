import Testing
import Foundation
@testable import GargantuaCore

@Suite("OrganizationProposal validation")
struct OrganizationProposalValidationTests {

    // MARK: helpers

    private static let root = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

    private static func move(
        source: String,
        destination: String,
        id: UUID = UUID()
    ) -> MoveAction {
        MoveAction(
            id: id,
            sourceURL: URL(fileURLWithPath: source),
            destinationURL: URL(fileURLWithPath: destination)
        )
    }

    private static func plan(
        name: String = "Receipts",
        moves: [MoveAction] = [],
        id: UUID = UUID()
    ) -> OrganizationPlan {
        OrganizationPlan(id: id, name: name, reasoning: "test", moves: moves)
    }

    private static func proposal(plans: [OrganizationPlan]) -> OrganizationProposal {
        OrganizationProposal(
            sourceFolder: root,
            generatedAt: Date(timeIntervalSince1970: 0),
            backend: .cloud,
            plans: plans
        )
    }

    // MARK: happy path

    @Test("Valid proposal with files moving into a subfolder passes")
    func validProposalPasses() throws {
        let m = Self.move(
            source: "/Users/test/Downloads/receipt-jan.pdf",
            destination: "/Users/test/Downloads/Receipts/receipt-jan.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(moves: [m])])
        try p.validate()
    }

    // MARK: plan name guards

    @Test("Empty plan name is rejected")
    func emptyPlanNameRejected() {
        let planID = UUID()
        let m = Self.move(
            source: "/Users/test/Downloads/x.pdf",
            destination: "/Users/test/Downloads/Foo/x.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(name: "", moves: [m], id: planID)])
        #expect(throws: OrganizationProposal.ValidationError.invalidPlanName(planID: planID, name: "")) {
            try p.validate()
        }
    }

    @Test("Plan name with path separator is rejected")
    func planNameWithSlashRejected() {
        let m = Self.move(
            source: "/Users/test/Downloads/x.pdf",
            destination: "/Users/test/Downloads/A/B/x.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(name: "A/B", moves: [m])])
        #expect(throws: (any Error).self) { try p.validate() }
    }

    // MARK: source/destination boundary

    @Test("Move with source outside the scanned root is rejected")
    func sourceOutsideRootRejected() {
        let m = Self.move(
            source: "/Users/test/Documents/leaky.pdf",
            destination: "/Users/test/Downloads/Foo/leaky.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(moves: [m])])
        #expect(throws: (any Error).self) { try p.validate() }
    }

    @Test("Move with destination outside the scanned root is rejected")
    func destinationOutsideRootRejected() {
        let m = Self.move(
            source: "/Users/test/Downloads/x.pdf",
            destination: "/System/Library/Foo/x.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(moves: [m])])
        #expect(throws: (any Error).self) { try p.validate() }
    }

    @Test("Sibling-folder typosquat destination is rejected (DownloadsExtra vs Downloads)")
    func siblingFolderRejected() {
        let m = Self.move(
            source: "/Users/test/Downloads/x.pdf",
            destination: "/Users/test/DownloadsExtra/x.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(moves: [m])])
        #expect(throws: (any Error).self) { try p.validate() }
    }

    @Test("Destination directly in the scanned root (no subfolder) is rejected")
    func destinationFlatInRootRejected() {
        let m = Self.move(
            source: "/Users/test/Downloads/x.pdf",
            destination: "/Users/test/Downloads/x.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(moves: [m])])
        #expect(throws: (any Error).self) { try p.validate() }
    }

    @Test("Source equals destination is rejected")
    func sourceEqualsDestinationRejected() {
        let m = Self.move(
            source: "/Users/test/Downloads/Foo/x.pdf",
            destination: "/Users/test/Downloads/Foo/x.pdf"
        )
        let p = Self.proposal(plans: [Self.plan(moves: [m])])
        #expect(throws: (any Error).self) { try p.validate() }
    }
}

@Suite("UndoEntry JSON round-trip")
struct UndoEntryCodableTests {
    @Test("UndoEntry survives encode + decode")
    func roundTrip() throws {
        let entry = UndoEntry(
            originalURL: URL(fileURLWithPath: "/Users/test/Downloads/a.pdf"),
            appliedURL: URL(fileURLWithPath: "/Users/test/Downloads/Receipts/a.pdf"),
            appliedAt: Date(timeIntervalSince1970: 1_700_000_000),
            planID: UUID(),
            proposalID: UUID()
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(UndoEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("Array of UndoEntry round-trips (ledger shape)")
    func ledgerRoundTrip() throws {
        let entries = (0..<3).map { idx in
            UndoEntry(
                originalURL: URL(fileURLWithPath: "/Users/test/Downloads/\(idx).pdf"),
                appliedURL: URL(fileURLWithPath: "/Users/test/Downloads/Receipts/\(idx).pdf"),
                appliedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + idx)),
                planID: UUID(),
                proposalID: UUID()
            )
        }
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([UndoEntry].self, from: data)
        #expect(decoded == entries)
    }
}
