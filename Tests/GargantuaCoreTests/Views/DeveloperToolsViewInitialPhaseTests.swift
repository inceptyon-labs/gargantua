import Foundation
import Testing
@testable import GargantuaCore

private func availability(
    _ tool: DeveloperTool,
    installed: Bool,
    version: String? = nil,
    error: String? = nil
) -> DeveloperToolAvailability {
    DeveloperToolAvailability(
        tool: tool,
        isInstalled: installed,
        executable: installed ? URL(fileURLWithPath: "/usr/local/bin/\(tool.rawValue)") : nil,
        version: version,
        error: error
    )
}

@Suite("DeveloperToolsView.deriveInitialPhase")
struct DeveloperToolsViewInitialPhaseTests {

    @Test("No tools installed → .empty carrying the availabilities so the UI can show reasons")
    func emptyWhenNothingInstalled() {
        let availabilities = [
            availability(.homebrew, installed: false, error: "brew not found"),
            availability(.docker, installed: false, error: "docker not found"),
        ]

        let phase = DeveloperToolsView.deriveInitialPhase(availabilities: availabilities)

        guard case .empty(let carried) = phase else {
            Issue.record("expected .empty, got \(phase)")
            return
        }
        #expect(carried.count == 2)
        #expect(carried.allSatisfy { !$0.isInstalled })
    }

    @Test("At least one tool installed → .ready seeds installed tools with .loading")
    func readyWhenAnyInstalled() {
        let availabilities = [
            availability(.homebrew, installed: true, version: "Homebrew 4.2.0"),
            availability(.docker, installed: false, error: "docker not found"),
        ]

        let phase = DeveloperToolsView.deriveInitialPhase(availabilities: availabilities)

        guard case .ready(let carried, let previews) = phase else {
            Issue.record("expected .ready, got \(phase)")
            return
        }
        #expect(carried.count == 2)
        #expect(previews[.homebrew] == .loading)
        #expect(previews[.docker] == nil, "uninstalled tool should not be seeded with a preview")
    }

    @Test("All tools installed → both seeded as loading")
    func readyWhenAllInstalled() {
        let availabilities = [
            availability(.homebrew, installed: true),
            availability(.docker, installed: true),
        ]

        let phase = DeveloperToolsView.deriveInitialPhase(availabilities: availabilities)

        guard case .ready(_, let previews) = phase else {
            Issue.record("expected .ready, got \(phase)")
            return
        }
        #expect(previews[.homebrew] == .loading)
        #expect(previews[.docker] == .loading)
    }
}
