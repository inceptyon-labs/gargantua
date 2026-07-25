import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

/// The Developer Tools panel runs `docker system prune`, `brew autoremove`,
/// `go clean -modcache` and a dozen more destructive commands. Those must take
/// the same license gate as Deep Clean; before this suite existed the whole
/// panel was ungated.
@Suite("DeveloperToolsView destructive license gate")
struct DeveloperToolsExecutionGateTests {

    private func makeRequest() -> DeveloperToolsView.ExecutionRequest {
        DeveloperToolsView.ExecutionRequest(
            operation: .homebrewCleanup,
            preview: DeveloperToolPreview(
                tool: .homebrew,
                commandPreview: ["/opt/homebrew/bin/brew", "cleanup", "-n"],
                items: [],
                rawOutput: ""
            )
        )
    }

    @Test("a blocked gate stops the command before it runs")
    @MainActor
    func blockedGateStopsExecution() async {
        let ranCommand = Ref(false)
        let view = DeveloperToolsView(
            session: DeveloperToolsSessionState(),
            availabilityProvider: { [] },
            previewProvider: { tool in
                DeveloperToolPreview(tool: tool, commandPreview: [], items: [], rawOutput: "")
            },
            executionProvider: { _, _, _ in
                ranCommand.value = true
                return DeveloperToolExecutionResult(
                    operation: .homebrewCleanup,
                    commandPreview: ["/opt/homebrew/bin/brew", "cleanup"],
                    output: ProcessOutput(stdout: "", stderr: "", exitCode: 0),
                    estimatedBytesFreed: 0
                )
            },
            gateDecision: { .blocked(reason: .trialExpired) }
        )

        await view.runGatedExecution(makeRequest())

        #expect(ranCommand.value == false)
        #expect(view.session.blockedReason == .trialExpired)
        #expect(view.session.executingOperationID == nil)
    }

    @Test("an allowed gate runs the command exactly once")
    @MainActor
    func allowedGateRunsExecution() async {
        let runCount = Ref(0)
        let view = DeveloperToolsView(
            session: DeveloperToolsSessionState(),
            availabilityProvider: { [] },
            previewProvider: { tool in
                DeveloperToolPreview(tool: tool, commandPreview: [], items: [], rawOutput: "")
            },
            executionProvider: { _, _, _ in
                runCount.value += 1
                return DeveloperToolExecutionResult(
                    operation: .homebrewCleanup,
                    commandPreview: ["/opt/homebrew/bin/brew", "cleanup"],
                    output: ProcessOutput(stdout: "", stderr: "", exitCode: 0),
                    estimatedBytesFreed: 0
                )
            },
            gateDecision: { .allowed }
        )

        await view.runGatedExecution(makeRequest())

        #expect(runCount.value == 1)
        #expect(view.session.blockedReason == nil)
    }
}

/// Mutable box so the `@Sendable` provider closures can report back without
/// tripping the captured-var-in-concurrent-code diagnostic.
private final class Ref<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
