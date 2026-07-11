import Foundation
import Testing
@testable import GargantuaCore

@Suite("BackgroundItemRow action gating")
@MainActor
struct BackgroundItemRowGatingTests {

    func makeItem(
        source: BackgroundItemSource = .userLaunchAgent,
        safety: SafetyLevel = .review,
        reasons: Set<BackgroundItemReason> = [],
        runtime: LaunchdRuntimeState? = nil
    ) -> BackgroundItem {
        BackgroundItem(
            id: "userAgent|com.acme.tool|/tmp/com.acme.tool.plist",
            label: "com.acme.tool",
            source: source,
            plistPath: "/tmp/com.acme.tool.plist",
            executablePath: "/usr/local/bin/acme",
            identity: nil,
            safety: safety,
            reasons: reasons,
            explanation: "Test item",
            isOrphaned: false,
            runtime: runtime
        )
    }

    func makeRow(item: BackgroundItem, isSessionDisabled: Bool = false) -> BackgroundItemRow {
        BackgroundItemRow(
            item: item,
            isExpanded: false,
            isSessionDisabled: isSessionDisabled,
            onToggleExpand: {},
            onReveal: {}
        )
    }

    @Test("an item disabled via launchd's override DB reads as disabled")
    func overrideDisabledItemIsDisabled() {
        let runtime = LaunchdRuntimeState(
            isLoaded: false,
            pid: nil,
            lastExitStatus: nil,
            disabledOverride: true
        )
        let row = makeRow(item: makeItem(runtime: runtime))

        #expect(row.isDisabled)
        #expect(!row.canDisable)
        #expect(row.canEnable)
        #expect(row.canDelete)
    }

    @Test("an explicitly enabled override does not read as disabled")
    func enabledOverrideItemIsNotDisabled() {
        let runtime = LaunchdRuntimeState(
            isLoaded: true,
            pid: 42,
            lastExitStatus: nil,
            disabledOverride: false
        )
        let row = makeRow(item: makeItem(runtime: runtime))

        #expect(!row.isDisabled)
        #expect(row.canDisable)
        #expect(!row.canEnable)
        #expect(!row.canDelete)
    }

    @Test("runtime without an override leaves plist/session signals in charge")
    func nilOverrideFallsBackToExistingSignals() {
        let runtime = LaunchdRuntimeState(
            isLoaded: true,
            pid: 42,
            lastExitStatus: nil,
            disabledOverride: nil
        )
        let enabledRow = makeRow(item: makeItem(runtime: runtime))
        #expect(!enabledRow.isDisabled)

        let sessionDisabledRow = makeRow(item: makeItem(runtime: runtime), isSessionDisabled: true)
        #expect(sessionDisabledRow.isDisabled)
    }
}
