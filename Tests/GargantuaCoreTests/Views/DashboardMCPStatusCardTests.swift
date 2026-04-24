import Foundation
import Testing
@testable import GargantuaCore

@Suite("Dashboard MCP status presentation")
struct DashboardMCPStatusCardTests {
    @Test("stopped snapshot presents idle stdio state")
    func stoppedPresentation() {
        let presentation = DashboardMCPStatusPresentation.make(
            from: .stopped(transportMode: .stdio)
        )

        #expect(presentation.title == "Stopped")
        #expect(presentation.detail == "stdio transport idle")
        #expect(presentation.clientSummary == "No clients")
        #expect(presentation.actionLabel == "Start")
        #expect(presentation.tone == .muted)
    }

    @Test("running snapshot surfaces transport and connected client")
    func runningPresentation() {
        let snapshot = MCPServerStatusSnapshot(
            state: .running,
            transportMode: .stdio,
            clients: [
                MCPConnectedClient(
                    id: "claude-code@1.0",
                    name: "claude-code",
                    version: "1.0"
                ),
            ]
        )

        let presentation = DashboardMCPStatusPresentation.make(from: snapshot)

        #expect(presentation.title == "Running")
        #expect(presentation.detail == "stdio transport · claude-code 1.0")
        #expect(presentation.clientSummary == "claude-code 1.0")
        #expect(presentation.actionLabel == "Stop")
        #expect(presentation.tone == .safe)
    }

    @Test("combined stdio and SSE mode has readable transport detail")
    func combinedTransportPresentation() {
        let snapshot = MCPServerStatusSnapshot(
            state: .running,
            transportMode: .stdioAndSSE
        )

        let presentation = DashboardMCPStatusPresentation.make(from: snapshot)

        #expect(presentation.detail == "stdio + SSE transport · no clients")
    }

    @Test("error snapshot surfaces the last error")
    func errorPresentation() {
        let snapshot = MCPServerStatusSnapshot(
            state: .error,
            lastErrorMessage: "Launch agent unavailable."
        )

        let presentation = DashboardMCPStatusPresentation.make(from: snapshot)

        #expect(presentation.title == "Needs attention")
        #expect(presentation.detail == "Launch agent unavailable.")
        #expect(presentation.actionLabel == "Start")
        #expect(presentation.tone == .review)
    }
}
