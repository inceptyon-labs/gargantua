import Testing
import Foundation
@testable import GargantuaCore

@MainActor
@Suite("OrganizerSessionState lifecycle")
struct OrganizerSessionStateTests {

    // MARK: helpers

    /// Build a self-contained scratch root + state with a local proposer
    /// pointed at it. The state's `selectedTarget` resolves URLs from
    /// `~`, which we override by passing a custom proposer + executor;
    /// to drive a real Apply we trigger it directly with a hand-built
    /// proposal that already points at our scratch tree.
    private static func scratchRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("organizer-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func touch(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func makeProposal(root: URL) -> OrganizationProposal {
        let m1 = MoveAction(
            sourceURL: root.appendingPathComponent("a.pdf"),
            destinationURL: root.appendingPathComponent("Documents/a.pdf")
        )
        let m2 = MoveAction(
            sourceURL: root.appendingPathComponent("b.pdf"),
            destinationURL: root.appendingPathComponent("Documents/b.pdf")
        )
        let plan = OrganizationPlan(name: "Documents", reasoning: "test", moves: [m1, m2])
        return OrganizationProposal(
            sourceFolder: root,
            generatedAt: Date(timeIntervalSince1970: 0),
            backend: .local,
            plans: [plan]
        )
    }

    private static func makeExecutor(_ ledgerDir: URL) -> OrganizerExecutor {
        OrganizerExecutor(ledger: UndoLedger(ledgerDirectory: ledgerDir))
    }

    /// Spin the runloop until `condition()` is true (or `timeout`).
    private static func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @MainActor () -> Bool
    ) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Initial state

    @Test("Starts in idle phase with no proposal")
    func startsIdle() {
        let state = OrganizerSessionState()
        #expect(state.phase == .idle)
        #expect(state.proposal == nil)
        #expect(state.selectedTarget == .downloads)
    }

    // MARK: - Apply happy path

    @Test("Apply transitions preview → applying → applied with moved file count")
    func applyHappyPath() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.touch("a.pdf", in: root)
        _ = try Self.touch("b.pdf", in: root)

        let state = OrganizerSessionState(
            executor: Self.makeExecutor(root.appendingPathComponent("ledger"))
        )
        // Inject a proposal pointing at the scratch tree by simulating a
        // successful scan: write directly to the internal proposal +
        // phase by going through preview state.
        state.injectProposalForTesting(Self.makeProposal(root: root))
        #expect(state.phase == .preview)

        state.applyAll()
        await Self.waitUntil { state.phase != .applying && state.phase != .preview }

        if case .applied(let summary) = state.phase {
            #expect(summary.totalMoved == 2)
            #expect(summary.failed.isEmpty)
        } else {
            Issue.record("Expected .applied, got \(state.phase)")
        }
    }

    // MARK: - Undo round-trip

    @Test("Undo after apply reverses moves and ends in .undone")
    func undoAfterApply() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.touch("a.pdf", in: root)
        _ = try Self.touch("b.pdf", in: root)

        let state = OrganizerSessionState(
            executor: Self.makeExecutor(root.appendingPathComponent("ledger"))
        )
        state.injectProposalForTesting(Self.makeProposal(root: root))

        state.applyAll()
        await Self.waitUntil { if case .applied = state.phase { return true } else { return false } }

        state.undoLastApply()
        await Self.waitUntil { if case .undone = state.phase { return true } else { return false } }

        if case .undone(let summary) = state.phase {
            #expect(summary.reversed.count == 2)
            #expect(summary.failed.isEmpty)
        } else {
            Issue.record("Expected .undone, got \(state.phase)")
        }
        // Originals back in place.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.pdf").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.pdf").path))
    }

    // MARK: - Trash subfolder

    @Test("trashSubfolder moves a real folder to the Trash and records its path")
    func trashSubfolderHappyPath() throws {
        let s = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: s) }
        let sub = s.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("a.pdf"))

        let state = OrganizerSessionState()
        state.trashSubfolder(at: sub)

        #expect(state.trashedFolderPaths.contains(sub.standardizedFileURL.path))
        #expect(state.folderTrashErrors[sub.standardizedFileURL.path] == nil)
        #expect(!FileManager.default.fileExists(atPath: sub.path))
    }

    @Test("trashSubfolder on a missing folder records success (file already gone)")
    func trashSubfolderMissing() throws {
        let s = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: s) }
        let missing = s.appendingPathComponent("Never-Existed", isDirectory: true)

        let state = OrganizerSessionState()
        state.trashSubfolder(at: missing)

        #expect(state.trashedFolderPaths.contains(missing.standardizedFileURL.path))
        #expect(state.folderTrashErrors[missing.standardizedFileURL.path] == nil)
    }

    @Test("Reset clears trashed folder state alongside proposal")
    func resetClearsTrashedState() throws {
        let s = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: s) }
        let sub = s.appendingPathComponent("Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let state = OrganizerSessionState()
        state.trashSubfolder(at: sub)
        #expect(!state.trashedFolderPaths.isEmpty)

        state.reset()
        #expect(state.trashedFolderPaths.isEmpty)
        #expect(state.folderTrashErrors.isEmpty)
    }

    // MARK: - Reset

    @Test("Reset clears proposal and returns to idle")
    func resetReturnsIdle() {
        let state = OrganizerSessionState()
        state.injectProposalForTesting(Self.makeProposal(root: URL(fileURLWithPath: "/tmp/x")))
        #expect(state.phase == .preview)
        state.reset()
        #expect(state.phase == .idle)
        #expect(state.proposal == nil)
    }

    // MARK: - Cloud preference w/o service

    @Test("startScan with cloud preference and no service surfaces a failed phase")
    func cloudWithoutServiceFails() async throws {
        let root = try Self.scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Self.touch("a.pdf", in: root)
        _ = try Self.touch("b.pdf", in: root)

        let state = OrganizerSessionState(
            executor: Self.makeExecutor(root.appendingPathComponent("ledger")),
            cloudService: nil,
            preferenceProvider: { .cloud }
        )
        // selectedTarget defaults to .downloads which resolves to ~/Downloads;
        // we don't care which folder we point at because the failure is the
        // missing cloud service, not folder access. But to avoid touching
        // ~/Downloads in tests, swap in a scratch downloads via injection
        // would require API changes. Instead: trigger and just look for
        // a non-success terminal phase.
        state.startScan()
        await Self.waitUntil { if case .failed = state.phase { return true } else { return false } }

        if case .failed = state.phase {
            // expected
        } else {
            Issue.record("Expected .failed for cloud without service, got \(state.phase)")
        }
    }
}

// MARK: - Test-only hooks

extension OrganizerSessionState {
    /// Test-only seam: skip the scan and land directly in preview state.
    /// Production code calls `startScan()` which drives this transition
    /// via a proposer. Tests want to exercise apply / undo without
    /// touching `~/Downloads` or wiring a fake transport.
    @MainActor
    func injectProposalForTesting(_ proposal: OrganizationProposal) {
        // We need package-private access to the published vars. Both
        // are declared `public private(set)`, so we route through
        // dedicated test mutators below.
        _testSetProposal(proposal)
        _testSetPhase(.preview)
    }
}
