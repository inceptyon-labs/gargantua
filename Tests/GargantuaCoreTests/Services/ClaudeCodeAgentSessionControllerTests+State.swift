import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentSessionControllerTests {
    @Test("Initial state is idle with empty events, gates, and no active session")
    func initialState() {
        let controller = ClaudeCodeAgentSessionController()
        #expect(controller.status == .idle)
        #expect(controller.events.isEmpty)
        #expect(controller.approvalGates.isEmpty)
        #expect(controller.activeSessionID == nil)
    }

    @Test("The raw transcript keeps the latest lines and shortens huge ones")
    func rawTranscriptIsCapped() {
        let controller = ClaudeCodeAgentSessionController()
        let limit = ClaudeCodeAgentSessionController.rawTranscriptLimit
        for index in 0 ..< limit + 20 {
            controller.appendRawEvent(ClaudeCodeAgentTranscriptEvent(stream: .stdout, message: "line \(index)"))
        }
        controller.appendRawEvent(ClaudeCodeAgentTranscriptEvent(
            stream: .stdout,
            message: String(repeating: "x", count: 1_000_000)
        ))

        #expect(controller.events.count == limit)
        #expect(controller.events.first?.message == "line 21")
        #expect((controller.events.last?.message.utf8.count ?? 0) < ClaudeCodeAgentSessionController.rawLineLimit + 64)
    }

    @Test("cancel() while idle is a no-op — status remains idle")
    func cancelWhileIdleIsNoOp() {
        let controller = ClaudeCodeAgentSessionController()
        controller.cancel()
        #expect(controller.status == .idle)
        #expect(controller.activeSessionID == nil)
    }

    @Test("approve() with no matching gate is a no-op — gate list stays empty")
    func approveOnEmptyGatesIsNoOp() {
        let controller = ClaudeCodeAgentSessionController()
        let stranger = ClaudeCodeAgentApprovalGate(
            sessionID: UUID(),
            summary: "stranger gate",
            rawTranscript: ""
        )
        controller.approve(stranger)
        #expect(controller.approvalGates.isEmpty)
    }

    @Test("deny() with no matching gate is a no-op — gate list stays empty")
    func denyOnEmptyGatesIsNoOp() {
        let controller = ClaudeCodeAgentSessionController()
        let stranger = ClaudeCodeAgentApprovalGate(
            sessionID: UUID(),
            summary: "stranger gate",
            rawTranscript: ""
        )
        controller.deny(stranger)
        #expect(controller.approvalGates.isEmpty)
    }

    @Test("ClaudeCodeAgentSessionStatus.isRunning is true only for .running")
    func sessionStatusIsRunningSemantics() {
        #expect(ClaudeCodeAgentSessionStatus.idle.isRunning == false)
        #expect(ClaudeCodeAgentSessionStatus.running.isRunning == true)
        #expect(ClaudeCodeAgentSessionStatus.completed.isRunning == false)
        #expect(ClaudeCodeAgentSessionStatus.failed("err").isRunning == false)
        #expect(ClaudeCodeAgentSessionStatus.cancelled.isRunning == false)
    }

    @Test("ClaudeCodeAgentSessionStatus.label is human-readable for each case")
    func sessionStatusLabels() {
        #expect(ClaudeCodeAgentSessionStatus.idle.label == "Ready")
        #expect(ClaudeCodeAgentSessionStatus.running.label == "Running")
        #expect(ClaudeCodeAgentSessionStatus.completed.label == "Completed")
        #expect(ClaudeCodeAgentSessionStatus.failed("x").label == "Failed")
        #expect(ClaudeCodeAgentSessionStatus.cancelled.label == "Cancelled")
    }
}
