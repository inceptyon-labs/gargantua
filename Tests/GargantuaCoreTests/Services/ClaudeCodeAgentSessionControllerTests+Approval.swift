// swiftlint:disable line_length
// Test fixtures embed real Claude Code JSONL stream records inline as
// raw strings. Each record is one logical JSON line by spec; breaking
// them across source lines would corrupt the assertion data.

import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentSessionControllerTests {
    @Test("Assistant-text plan narration mentioning mcp__gargantua__clean and item_ids does not raise a gate")
    func assistantTextEchoDoesNotRaiseGate() async throws {
        // Regression: the agent's prompt instructs it to call
        // `mcp__gargantua__clean` with `item_ids` and `dry_run: true`, so its
        // assistant messages narrating the plan routinely contain both
        // tokens. With the substring fallback removed, only structured
        // tool_use payloads (parsed by ClaudeCodeStreamJSONParser into
        // proposedItemIDs) raise gates — assistant-text echoes do not.
        let assistantTextLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will call mcp__gargantua__clean with item_ids: [\"safe-1\"] and dry_run: true."}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(assistantTextLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        #expect(controller.approvalGates.isEmpty)
    }

    @Test("approve() with proposedItemIDs but empty scan cache surfaces unresolved IDs — view renders Smart Uninstaller note")
    func approveWithProposedIDsButEmptyCacheSurfacesUnresolved() async throws {
        // Stream-json clean call without a preceding scan tool_result.
        // Detector parses item_ids onto the gate; controller's host cache
        // is empty so lookupAll resolves nothing — but we still surface
        // pendingApproval with empty items + the unresolved IDs so the
        // agent view can render the inline "use Smart Uninstaller" note
        // for app-bundle paths the agent proposed by hand.
        let cleanLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_empty","name":"mcp__gargantua__clean","input":{"item_ids":["chrome_cache-1"],"method":"trash","confirm":true}}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(cleanLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        #expect(gate.proposedItemIDs == ["chrome_cache-1"])

        controller.approve(gate)

        let pending = try #require(controller.pendingApproval)
        #expect(pending.gateID == gate.id)
        #expect(pending.items.isEmpty)
        #expect(pending.unresolvedItemIDs == ["chrome_cache-1"])
        // Gate stays pending until user dismisses the note.
        #expect(controller.approvalGates.first?.status == .pending)
    }

    @Test("confirmPendingApproval with empty items still marks gate approved — Smart Uninstaller note acknowledged")
    func confirmPendingApprovalWithEmptyItemsMarksGateApproved() async throws {
        // Same all-unresolved setup as above. After the user dismisses the
        // Smart Uninstaller note via confirm, the gate transitions to
        // approved with audit even though no cleanup ran.
        let cleanLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_only_unresolved","name":"mcp__gargantua__clean","input":{"item_ids":["bundle-path-1","bundle-path-2"],"method":"trash","confirm":true}}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(cleanLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        controller.approve(gate)

        let pending = try #require(controller.pendingApproval)
        #expect(pending.items.isEmpty)
        #expect(pending.unresolvedItemIDs.count == 2)

        await controller.confirmPendingApproval()

        #expect(controller.pendingApproval == nil)
        #expect(controller.approvalGates.first?.status == .approved)
    }

    @Test("stream-json scan tool_result populates the host cache; approve() then hydrates matching IDs into pendingApproval")
    func approveHydratesItemsAfterScanStreamEvent() async throws {
        // Two stream-json lines: first a scan tool_result the controller
        // mirrors into its cache, then a clean tool_use whose item_ids
        // overlap. After session ends, approve(_:) on the captured gate
        // should hydrate items[0] from the cache.
        let scanResultLine = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_scan_xaad","type":"tool_result","content":"summary text"}]},"tool_use_result":{"content":"summary text","structuredContent":{"items":[{"id":"chrome_cache-1","name":"Chrome","path":"/tmp/chrome-cache","size":"1.2 KB","safety":"safe","confidence":90,"explanation":"cache","source":"Chrome","category":"browser_cache"},{"id":"npm_cache-2","name":"npm","path":"/tmp/npm-cache","size":"500 bytes","safety":"safe","confidence":85,"explanation":"npm cache","source":"npm","category":"dev_artifacts"}],"summary":{"safe_count":2,"safe_size":"1.7 KB","review_count":0,"review_size":"0 bytes","protected_count":0},"total_reclaimable":"1.7 KB"}}}
        """#
        let cleanCallLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_xaad","name":"mcp__gargantua__clean","input":{"item_ids":["chrome_cache-1","unknown-99"],"method":"trash","confirm":true}}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(scanResultLine + "\n"),
            .stdout(cleanCallLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)

        controller.start(template: .investigateSpace, userContext: "scan")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        #expect(gate.proposedItemIDs == ["chrome_cache-1", "unknown-99"])

        controller.approve(gate)

        let pending = try #require(controller.pendingApproval)
        #expect(pending.gateID == gate.id)
        #expect(pending.items.count == 1)
        #expect(pending.items.first?.id == "chrome_cache-1")
        #expect(pending.unresolvedItemIDs == ["unknown-99"])
        // Gate stays pending until the user confirms in the modal.
        #expect(controller.approvalGates.first?.status == .pending)

        // Verify cancel path tears it back down without touching the gate.
        controller.cancelPendingApproval()
        #expect(controller.pendingApproval == nil)
        #expect(controller.approvalGates.first?.status == .pending)
    }

    @Test("approve() only hydrates safe and review scan items from the Trust Layer")
    func approveFiltersProtectedScanItems() async throws {
        // The agent may only hand item IDs back into the host. Even if a
        // protected ID appears in a proposed clean call, the controller
        // defers to Gargantua's scan-derived safety and keeps that row out
        // of the cleanup modal.
        let scanResultLine = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_scan_protected","type":"tool_result","content":"summary"}]},"tool_use_result":{"content":"summary","structuredContent":{"items":[{"id":"safe-1","name":"Safe","path":"/tmp/safe-1","size":"1 KB","safety":"safe","confidence":90,"explanation":"cache","source":"Rules","category":"browser_cache"},{"id":"review-1","name":"Review","path":"/tmp/review-1","size":"2 KB","safety":"review","confidence":80,"explanation":"review","source":"Rules","category":"app_data"},{"id":"protected-1","name":"Protected","path":"/Users/Jason/Library","size":"3 KB","safety":"protected","confidence":99,"explanation":"protected","source":"Rules","category":"system_cache"}],"summary":{"safe_count":1,"safe_size":"1 KB","review_count":1,"review_size":"2 KB","protected_count":1},"total_reclaimable":"3 KB"}}}
        """#
        let cleanCallLine = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_clean_protected","name":"mcp__gargantua__clean","input":{"item_ids":["safe-1","review-1","protected-1"],"method":"trash","confirm":true,"dry_run":true}}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(scanResultLine + "\n"),
            .stdout(cleanCallLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)

        controller.start(template: .investigateSpace, userContext: "audit")
        _ = await waitForTerminalStatus(controller)

        let gate = try #require(controller.approvalGates.first)
        controller.approve(gate)

        let pending = try #require(controller.pendingApproval)
        #expect(pending.items.map(\.id) == ["safe-1", "review-1"])
        #expect(pending.unresolvedItemIDs.isEmpty)
        #expect(controller.events.contains {
            $0.stream == .system && $0.message.contains("Skipped protected agent cleanup item(s): protected-1")
        })
    }

    @Test("Last assistant text is captured and surfaced for the WHY-these-items modal header")
    func lastAssistantTextCapturedForWhySurface() async throws {
        // Two assistant_text events; controller should retain the most
        // recent non-empty one. Empty/whitespace events are ignored so a
        // trailing tool_use turn (which can carry a blank text block in
        // some Sonnet outputs) doesn't wipe the meaningful prose.
        let firstText = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at your installed apps and stale caches."}]}}
        """#
        let secondText = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"These are stale Adobe caches the parent app no longer reads — safe to remove for a macOS upgrade."}]}}
        """#
        let blankText = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"   "}]}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(firstText + "\n"),
            .stdout(secondText + "\n"),
            .stdout(blankText + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "audit")
        _ = await waitForTerminalStatus(controller)

        #expect(controller.lastAssistantText == "These are stale Adobe caches the parent app no longer reads — safe to remove for a macOS upgrade.")
    }

    @Test("Cleanup progress publishers expose isCleaning + counts so the view can render the overlay")
    func cleanupProgressPublishedForOverlay() async throws {
        // Drive a session that ends with a synthetic gate (host fallback),
        // then fire confirmPendingApproval and observe the publishers.
        // Default trash backend is fine — we only assert the published
        // state, not the actual filesystem effect.
        let scanResultLine = #"""
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_scan_progress","type":"tool_result","content":"summary"}]},"tool_use_result":{"content":"summary","structuredContent":{"items":[{"id":"a","name":"A","path":"/tmp/nonexistent-a-\#(UUID().uuidString)","size":"100 bytes","safety":"safe","confidence":90,"explanation":"x","source":"X","category":"browser_cache"}],"summary":{"safe_count":1,"safe_size":"100 bytes","review_count":0,"review_size":"0 bytes","protected_count":0},"total_reclaimable":"100 bytes"}}}
        """#
        let runner = try makeRunner(executor: ControllerFakeProcessExecutor(outputs: [
            .stdout(scanResultLine + "\n"),
        ]))
        let controller = ClaudeCodeAgentSessionController(runner: runner)
        controller.start(template: .investigateSpace, userContext: "audit")
        _ = await waitForTerminalStatus(controller)

        // Initial state: not cleaning yet.
        #expect(controller.isCleaning == false)
        #expect(controller.cleaningProgress == 0)

        // The fallback should have already populated pendingApproval.
        #expect(controller.pendingApproval != nil)

        // Run cleanup. CleanupEngine emits per-item progress events that
        // the observer routes back to the controller; on completion both
        // flags reset.
        await controller.confirmPendingApproval(method: .delete)

        #expect(controller.isCleaning == false)
        #expect(controller.cleaningProgress == 0)
        #expect(controller.cleaningTotal == 0)
        // The approved gate landed in approvalGates with .approved status.
        let gate = try #require(controller.approvalGates.first)
        #expect(gate.status == .approved)
    }
}
// swiftlint:enable line_length
