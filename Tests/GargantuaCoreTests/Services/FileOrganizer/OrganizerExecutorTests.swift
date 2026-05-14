import Testing
import Foundation
@testable import GargantuaCore

@Suite("OrganizerExecutor apply + undo")
struct OrganizerExecutorTests {

    // MARK: helpers

    /// One self-contained scratch environment: a source folder plus an
    /// isolated ledger directory. Teardown removes both.
    private struct Scratch {
        let root: URL
        let ledgerDir: URL
        let ledger: UndoLedger
        let executor: OrganizerExecutor

        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("organizer-exec-\(UUID().uuidString)", isDirectory: true)
            self.root = base.appendingPathComponent("Downloads", isDirectory: true)
            self.ledgerDir = base.appendingPathComponent("ledger", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
            self.ledger = UndoLedger(ledgerDirectory: ledgerDir)
            self.executor = OrganizerExecutor(ledger: ledger)
        }

        func touch(_ name: String, contents: String = "x") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    private static func proposal(
        root: URL,
        plans: [(name: String, fileNames: [String])]
    ) -> OrganizationProposal {
        let mapped = plans.map { plan -> OrganizationPlan in
            let moves = plan.fileNames.map { name in
                MoveAction(
                    sourceURL: root.appendingPathComponent(name),
                    destinationURL: root.appendingPathComponent(plan.name).appendingPathComponent(name)
                )
            }
            return OrganizationPlan(name: plan.name, reasoning: "test", moves: moves)
        }
        return OrganizationProposal(
            sourceFolder: root,
            generatedAt: Date(timeIntervalSince1970: 0),
            backend: .local,
            plans: mapped
        )
    }

    // MARK: apply

    @Test("Apply moves files into target subfolder and records ledger entries")
    func applyMovesAndLogs() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.touch("a.pdf")
        _ = try s.touch("b.pdf")

        let p = Self.proposal(root: s.root, plans: [("Documents", ["a.pdf", "b.pdf"])])
        let result = try s.executor.apply(p)

        #expect(result.totalMoved == 2)
        #expect(result.failed.isEmpty)
        let destA = s.root.appendingPathComponent("Documents/a.pdf")
        let destB = s.root.appendingPathComponent("Documents/b.pdf")
        #expect(FileManager.default.fileExists(atPath: destA.path))
        #expect(FileManager.default.fileExists(atPath: destB.path))
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent("a.pdf").path))

        let entries = try s.ledger.entries(forProposalID: p.id)
        #expect(entries.count == 2)
    }

    @Test("Apply skips files that vanished between scan and execute")
    func applySkipsMissingSource() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.touch("a.pdf")
        // b.pdf in the proposal but never touched on disk

        let p = Self.proposal(root: s.root, plans: [("Documents", ["a.pdf", "b.pdf"])])
        let result = try s.executor.apply(p)

        #expect(result.totalMoved == 1)
        #expect(result.skipped.count == 1)
        #expect(result.failed.isEmpty)
    }

    @Test("Apply refuses to clobber an existing destination")
    func applyDoesNotClobber() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.touch("a.pdf", contents: "source-content")
        // Pre-create destination with different contents
        let destFolder = s.root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let existingDest = destFolder.appendingPathComponent("a.pdf")
        try Data("existing-content".utf8).write(to: existingDest)

        let p = Self.proposal(root: s.root, plans: [("Documents", ["a.pdf"])])
        let result = try s.executor.apply(p)

        #expect(result.failed.count == 1)
        #expect(result.totalMoved == 0)
        // Existing destination preserved.
        let stillThere = try Data(contentsOf: existingDest)
        #expect(String(data: stillThere, encoding: .utf8) == "existing-content")
        // Source untouched.
        let src = try Data(contentsOf: s.root.appendingPathComponent("a.pdf"))
        #expect(String(data: src, encoding: .utf8) == "source-content")
    }

    @Test("Apply refuses an invalid proposal (out-of-root move)")
    func applyRefusesInvalid() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let bogusMove = MoveAction(
            sourceURL: URL(fileURLWithPath: "/etc/hosts"),
            destinationURL: s.root.appendingPathComponent("Documents/hosts")
        )
        let plan = OrganizationPlan(name: "Documents", reasoning: "x", moves: [bogusMove])
        let p = OrganizationProposal(
            sourceFolder: s.root,
            generatedAt: Date(),
            backend: .local,
            plans: [plan]
        )
        #expect(throws: (any Error).self) { try s.executor.apply(p) }
    }

    // MARK: undo

    @Test("Undo reverses applied moves and removes the empty target folder")
    func undoReversesMoves() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.touch("a.pdf", contents: "a")
        _ = try s.touch("b.pdf", contents: "b")

        let p = Self.proposal(root: s.root, plans: [("Documents", ["a.pdf", "b.pdf"])])
        _ = try s.executor.apply(p)

        let result = try s.executor.undo(proposalID: p.id)

        #expect(result.failed.isEmpty)
        #expect(result.reversed.count == 2)
        #expect(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("a.pdf").path))
        #expect(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("b.pdf").path))
        // Target subfolder was emptied and removed.
        #expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent("Documents").path))
        // Ledger is now empty for this proposal.
        #expect(try s.ledger.entries(forProposalID: p.id).isEmpty)
    }

    @Test("Undo refuses to clobber a re-created original")
    func undoDoesNotClobber() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.touch("a.pdf", contents: "original")

        let p = Self.proposal(root: s.root, plans: [("Documents", ["a.pdf"])])
        _ = try s.executor.apply(p)

        // User creates a new a.pdf at the original location after Apply.
        try Data("new-content".utf8).write(to: s.root.appendingPathComponent("a.pdf"))

        let result = try s.executor.undo(proposalID: p.id)

        #expect(result.failed.count == 1)
        // The moved copy stays in Documents/a.pdf — we did not clobber.
        let moved = s.root.appendingPathComponent("Documents/a.pdf")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        // The user's new file stays.
        let newContent = try Data(contentsOf: s.root.appendingPathComponent("a.pdf"))
        #expect(String(data: newContent, encoding: .utf8) == "new-content")
        // Ledger retains entries because undo did not fully succeed.
        #expect(try s.ledger.entries(forProposalID: p.id).count == 1)
    }

    @Test("Undo on a deleted applied file counts as reversed (best-effort)")
    func undoOnDeletedAppliedFile() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        _ = try s.touch("a.pdf")

        let p = Self.proposal(root: s.root, plans: [("Documents", ["a.pdf"])])
        _ = try s.executor.apply(p)

        // User deletes the moved file before invoking Undo.
        try FileManager.default.removeItem(at: s.root.appendingPathComponent("Documents/a.pdf"))

        let result = try s.executor.undo(proposalID: p.id)
        #expect(result.failed.isEmpty)
        #expect(result.reversed.count == 1)
        // Ledger row cleared.
        #expect(try s.ledger.entries(forProposalID: p.id).isEmpty)
    }
}

@Suite("UndoLedger persistence")
struct UndoLedgerTests {
    private static func makeLedger() throws -> (UndoLedger, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (UndoLedger(ledgerDirectory: dir), dir)
    }

    private static func entry(proposalID: UUID = UUID(), idx: Int = 0) -> UndoEntry {
        UndoEntry(
            originalURL: URL(fileURLWithPath: "/tmp/\(idx)/a.pdf"),
            appliedURL: URL(fileURLWithPath: "/tmp/\(idx)/Documents/a.pdf"),
            appliedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + idx)),
            planID: UUID(),
            proposalID: proposalID
        )
    }

    @Test("Append + readAll round-trip")
    func appendRoundTrip() throws {
        let (ledger, dir) = try Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e1 = Self.entry(idx: 1)
        let e2 = Self.entry(idx: 2)
        try ledger.append(e1)
        try ledger.append(e2)
        let read = try ledger.readAll()
        #expect(read == [e1, e2])
    }

    @Test("entries(forProposalID:) filters by proposal")
    func entriesByProposal() throws {
        let (ledger, dir) = try Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pA = UUID()
        let pB = UUID()
        try ledger.append(Self.entry(proposalID: pA, idx: 1))
        try ledger.append(Self.entry(proposalID: pB, idx: 2))
        try ledger.append(Self.entry(proposalID: pA, idx: 3))

        let a = try ledger.entries(forProposalID: pA)
        let b = try ledger.entries(forProposalID: pB)
        #expect(a.count == 2)
        #expect(b.count == 1)
    }

    @Test("clear(proposalID:) removes that proposal, keeps others")
    func clearFilters() throws {
        let (ledger, dir) = try Self.makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pA = UUID()
        let pB = UUID()
        try ledger.append(Self.entry(proposalID: pA, idx: 1))
        try ledger.append(Self.entry(proposalID: pB, idx: 2))

        try ledger.clear(proposalID: pA)
        let all = try ledger.readAll()
        #expect(all.count == 1)
        #expect(all.first?.proposalID == pB)
    }

    @Test("readAll on missing file returns empty")
    func readAllNoFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let ledger = UndoLedger(ledgerDirectory: dir)
        #expect(try ledger.readAll().isEmpty)
    }
}
