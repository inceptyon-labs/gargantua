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
    private func blockedResult(id: String = "b", safety: SafetyLevel = .safe) -> ScanResult {
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
            blockedByApp: BlockedApp(bundleID: "com.brave.Browser", name: "Brave Browser")
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
        let session = DeepCleanSessionState(appTerminator: term)
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
        let session = DeepCleanSessionState(appTerminator: StubTerminator(exits: true))
        session.finishScan(results: [blockedResult(id: "cache"), blockedResult(id: "storage", safety: .review)], duration: 0)

        _ = await session.quitBlockingApp(for: "cache")

        #expect(session.selectedResultIDs == ["cache"])
        #expect(session.isSelectable("storage"))
    }

    @Test("If the app refuses to quit, the item stays blocked and unselected")
    func quitFailureKeepsBlocked() async {
        let session = DeepCleanSessionState(appTerminator: StubTerminator(exits: false))
        session.finishScan(results: [blockedResult()], duration: 0)

        let ok = await session.quitBlockingApp(for: "b")

        #expect(!ok)
        #expect(session.blockedApp(for: "b") != nil)
        #expect(!session.isSelectable("b"))
        #expect(session.selectedResultIDs.isEmpty)
    }
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
