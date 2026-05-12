// swiftlint:disable line_length
import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentTests {
    @Test("Destructive action detector creates default-deny approval gate from structured tool_use payload")
    func destructiveActionDetectorCreatesGate() {
        let sessionID = UUID()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let line = #"{"type":"tool_use","name":"mcp__gargantua__clean","input":{"item_ids":["safe-1"],"confirm":true}}"#

        let gate = detector.detect(line, proposedItemIDs: ["safe-1"])

        #expect(gate?.sessionID == sessionID)
        #expect(gate?.status == .pending)
        #expect(gate?.rawTranscript == line)
        #expect(gate?.proposedItemIDs == ["safe-1"])
    }

    @Test("Detector ignores assistant text mentioning the clean tool — only structured tool_use payloads gate")
    func detectorIgnoresPromptEcho() {
        // The agent's prompt now instructs it to call mcp__gargantua__clean
        // with item_ids, so its assistant messages frequently echo both
        // tokens. Without this guard, every plan-narration message would
        // trip a duplicate gate. Only structured tool_use payloads (which
        // populate proposedItemIDs via the stream-json parser) should fire.
        let sessionID = UUID()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let assistantNarration = #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll call mcp__gargantua__clean with item_ids: [\"safe-1\"] and dry_run: true."}]}}"#

        let gate = detector.detect(assistantNarration, proposedItemIDs: [])

        #expect(gate == nil)
    }

    @Test("Detector with structured proposedItemIDs stamps them on the gate and includes the count in the summary")
    func detectorAttachesProposedItemIDs() {
        let sessionID = UUID()
        let detector = ClaudeCodeDestructiveActionDetector(sessionID: sessionID)
        let line = "free-form agent narration that doesn't substring-match"

        let gate = detector.detect(line, proposedItemIDs: ["chrome_cache-1", "npm_cache-2"])

        #expect(gate?.proposedItemIDs == ["chrome_cache-1", "npm_cache-2"])
        #expect(gate?.summary.contains("2 items") == true)
    }
}
// swiftlint:enable line_length
