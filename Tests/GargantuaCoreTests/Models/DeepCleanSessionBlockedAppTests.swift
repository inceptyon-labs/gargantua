import Foundation
import Testing
@testable import GargantuaCore

@MainActor
private final class StubTerminator: RunningApplicationTerminating {
    let exits: Bool
    private(set) var terminated: [String] = []
    init(exits: Bool = true) { self.exits = exits }
    func terminateRunningApplications(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        terminated.append(bundleIdentifier)
        return exits
    }
}

@Suite("DeepCleanSessionState app-blocked items")
@MainActor
struct DeepCleanSessionBlockedAppTests {
    private func blockedResult(
        id: String = "b",
        safety: SafetyLevel = .safe,
        ownerProcesses: [String]? = nil
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Brave Browser Cache",
            path: "/Users/x/Library/Caches/BraveSoftware/\(id)",
            size: 100,
            safety: safety,
            confidence: 95,
            explanation: "cache",
            source: SourceAttribution(name: "Brave Browser"),
            category: "browser_cache",
            blockedByApp: BlockedApp(bundleID: "com.brave.Browser", name: "Brave Browser"),
            ownerProcesses: ownerProcesses
        )
    }

    @Test("A safe item blocked by a running app is locked and not auto-selected")
    func blockedItemNotAutoSelected() {
        let session = DeepCleanSessionState(appTerminator: StubTerminator())
        session.finishScan(results: [blockedResult()], duration: 0)

        #expect(session.selectedResultIDs.isEmpty)
        #expect(!session.isSelectable("b"))
        #expect(session.blockedApp(for: "b")?.bundleID == "com.brave.Browser")
    }

    @Test("Quitting the app unblocks and selects every item it held, in place")
    func quitUnblocksAndSelects() async {
        let term = StubTerminator(exits: true)
        let session = DeepCleanSessionState(appTerminator: term, processChecker: RunningStub(running: []))
        // Two items held by the same app — both should unblock on a single quit.
        session.finishScan(results: [blockedResult(id: "a"), blockedResult(id: "b")], duration: 0)

        let ok = await session.quitBlockingApp(for: "a")

        #expect(ok)
        #expect(term.terminated == ["com.brave.Browser"])
        #expect(session.blockedApp(for: "a") == nil)
        #expect(session.blockedApp(for: "b") == nil)
        #expect(session.isSelectable("a"))
        #expect(session.selectedResultIDs.contains("a"))
        #expect(session.selectedResultIDs.contains("b"))
    }

    @Test("Quitting the app unlocks its review items without selecting them")
    func quitLeavesReviewItemsUnselected() async {
        let session = DeepCleanSessionState(appTerminator: StubTerminator(exits: true), processChecker: RunningStub(running: []))
        session.finishScan(results: [blockedResult(id: "cache"), blockedResult(id: "storage", safety: .review)], duration: 0)

        _ = await session.quitBlockingApp(for: "cache")

        #expect(session.selectedResultIDs == ["cache"])
        #expect(session.isSelectable("storage"))
    }

    @Test("If the app refuses to quit, the item stays blocked and unselected")
    func quitFailureKeepsBlocked() async {
        let session = DeepCleanSessionState(appTerminator: StubTerminator(exits: false), processChecker: RunningStub(running: []))
        session.finishScan(results: [blockedResult()], duration: 0)

        let ok = await session.quitBlockingApp(for: "b")

        #expect(!ok)
        #expect(session.blockedApp(for: "b") != nil)
        #expect(!session.isSelectable("b"))
        #expect(session.selectedResultIDs.isEmpty)
        #expect(session.scanProgress.errors == [Self.stillRunningMessage])
    }

    private static let stillRunningMessage =
        "com.brave.Browser is still running, so these items stay locked. Exit it, then rescan."

    @Test("A still-running CLI owner keeps items locked and the message is recorded once")
    func cliOwnerKeepsLocked() async {
        let session = DeepCleanSessionState(
            appTerminator: StubTerminator(exits: true),
            processChecker: RunningStub(running: ["codex"]),
            runningExecutablePaths: { _ in [] }
        )
        session.finishScan(results: [blockedResult(ownerProcesses: ["com.brave.Browser", "codex"])], duration: 0)

        let first = await session.quitBlockingApp(for: "b")
        let second = await session.quitBlockingApp(for: "b")

        #expect(!first)
        #expect(!second)
        #expect(session.blockedApp(for: "b") != nil)
        #expect(session.selectedResultIDs.isEmpty)
        #expect(session.scanProgress.errors == [Self.codexMessage])
    }

    private static let codexMessage =
        "codex is still running, so these items stay locked. Exit it, then rescan."
            + " It's a command-line process; quitting the app won't stop it."

    @Test("An owner running outside the app blocks the quit before the app is terminated")
    func outsideOwnerPreventsQuit() async {
        let term = StubTerminator(exits: true)
        let session = DeepCleanSessionState(
            appTerminator: term,
            processChecker: RunningStub(running: ["codex"]),
            runningExecutablePaths: { _ in ["/Users/x/.codex/packages/daemon/codex"] },
            bundlePathForApp: { _ in "/Applications/ChatGPT.app" },
            namesRunningApp: { _ in false }
        )
        session.finishScan(results: [codexResult()], duration: 0)

        #expect(await !session.quitBlockingApp(for: "c"))
        #expect(term.terminated.isEmpty)
        #expect(session.blockedApp(for: "c") != nil)
        let message = session.scanProgress.errors.first ?? ""
        #expect(message.contains("codex"))
        #expect(message.contains("command-line"))
    }

    @Test("An owner inside the app's bundle doesn't block the quit, and a stale message is removed")
    func insideOwnerQuits() async {
        let term = StubTerminator(exits: true)
        let checker = MutableStub()
        checker.running = ["codex"]
        let inside = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let session = DeepCleanSessionState(
            appTerminator: term,
            processChecker: checker,
            runningExecutablePaths: { _ in [inside] },
            bundlePathForApp: { _ in "/Applications/ChatGPT.app" },
            namesRunningApp: { _ in false }
        )
        session.finishScan(results: [codexResult()], duration: 0)
        session.scanProgress.recordError("codex is still running, so these items stay locked. Exit it, then rescan."
            + " It's a command-line process; quitting the app won't stop it.")
        // First attempt: codex survives the quit, so the message is posted (already present, not duplicated).
        #expect(await !session.quitBlockingApp(for: "c"))
        #expect(term.terminated == ["com.openai.codex"])
        #expect(session.scanProgress.errors.count == 1)

        checker.running = []
        #expect(await session.quitBlockingApp(for: "c"))
        #expect(session.blockedApp(for: "c") == nil)
        #expect(session.scanProgress.errors.isEmpty)
    }

    @Test("With no ownerProcesses, the blocker still running after the quit keeps items locked")
    func nilOwnersBlockerStillRunning() async {
        let session = DeepCleanSessionState(
            appTerminator: StubTerminator(exits: true),
            processChecker: RunningStub(running: ["com.brave.Browser"])
        )
        session.finishScan(results: [blockedResult(ownerProcesses: nil)], duration: 0)

        #expect(await !session.quitBlockingApp(for: "b"))
        #expect(session.blockedApp(for: "b") != nil)
        #expect(session.scanProgress.errors == [Self.stillRunningMessage])
    }

    private func codexResult() -> ScanResult {
        ScanResult(
            id: "c", name: "Codex", path: "/Users/x/.codex/c", size: 1, safety: .safe,
            confidence: 90, explanation: "x", source: SourceAttribution(name: "Codex"),
            category: "ai",
            blockedByApp: BlockedApp(bundleID: "com.openai.codex", name: "Codex"),
            ownerProcesses: ["com.openai.codex", "codex"]
        )
    }

    @Test("Quit unlocks when no owner is still running")
    func noOwnerRunningUnlocks() async {
        let session = DeepCleanSessionState(
            appTerminator: StubTerminator(exits: true),
            processChecker: RunningStub(running: []),
            runningExecutablePaths: { _ in [] }
        )
        session.finishScan(results: [blockedResult(ownerProcesses: ["com.brave.Browser", "codex"])], duration: 0)

        #expect(await session.quitBlockingApp(for: "b"))
        #expect(session.blockedApp(for: "b") == nil)
        #expect(session.selectedResultIDs == ["b"])
        #expect(session.scanProgress.errors.isEmpty)
    }
}

private final class MutableStub: RunningProcessChecking, @unchecked Sendable {
    var running: Set<String> = []
    func isRunning(identifier: String) -> Bool { running.contains(identifier) }
}

private struct RunningStub: RunningProcessChecking {
    let running: Set<String>
    func isRunning(identifier: String) -> Bool { running.contains(identifier) }
}

@Suite("NativeRuleGuardEvaluator.blockingApp")
struct BlockingAppTests {
    private struct StubChecker: RunningProcessChecking {
        let running: Set<String>
        func isRunning(identifier: String) -> Bool { running.contains(identifier) }
    }

    private func rule(guards: [String]) -> ScanRule {
        ScanRule(
            id: "r", name: "Brave Browser Cache", paths: ["~/x"],
            skipIfProcessRunning: guards,
            safety: .safe, confidence: 90, explanation: "c",
            source: SourceAttribution(name: "Brave Browser"),
            category: "browser_cache"
        )
    }

    @Test("Returns the running guard app with the rule's source name")
    func detectsRunning() {
        let app = NativeRuleGuardEvaluator.blockingApp(
            rule: rule(guards: ["com.brave.Browser"]),
            processChecker: StubChecker(running: ["com.brave.Browser"])
        )
        #expect(app?.bundleID == "com.brave.Browser")
        #expect(app?.name == "Brave Browser")
    }

    @Test("Returns nil when no guard process is running")
    func nilWhenNotRunning() {
        let app = NativeRuleGuardEvaluator.blockingApp(
            rule: rule(guards: ["com.brave.Browser"]),
            processChecker: StubChecker(running: [])
        )
        #expect(app == nil)
    }
}
