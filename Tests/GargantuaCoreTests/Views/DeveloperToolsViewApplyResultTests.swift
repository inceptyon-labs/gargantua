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

private func preview(
    tool: DeveloperTool,
    items: [DeveloperToolPreviewItem] = [],
    raw: String = ""
) -> DeveloperToolPreview {
    DeveloperToolPreview(
        tool: tool,
        commandPreview: ["/usr/local/bin/\(tool.rawValue)"],
        items: items,
        rawOutput: raw
    )
}

@Suite("DeveloperToolsView.applyPreviewResult")
struct DeveloperToolsViewApplyResultTests {

    @Test("Success result replaces .loading with .loaded")
    func successFlipsToLoaded() {
        let initial = DeveloperToolsView.deriveInitialPhase(availabilities: [
            availability(.homebrew, installed: true),
            availability(.docker, installed: true),
        ])
        let result = preview(tool: .homebrew, items: [
            DeveloperToolPreviewItem(
                id: "homebrew-0",
                tool: .homebrew,
                title: "Would remove: bottle foo (12MB)",
                reclaimableBytes: 12_000_000,
                commandPreview: ["brew", "cleanup", "-n"]
            ),
        ])

        let next = DeveloperToolsView.applyPreviewResult(
            tool: .homebrew,
            result: .success(result),
            to: initial
        )

        guard case .ready(_, let previews) = next else {
            Issue.record("expected .ready, got \(next)")
            return
        }
        #expect(previews[.homebrew] == .loaded(result))
        #expect(previews[.docker] == .loading, "other tool should be unaffected")
    }

    @Test("Post-run preview refresh replaces old reclaimable numbers")
    func postRunPreviewRefreshReplacesLoadedPreview() {
        let before = preview(tool: .docker, items: [
            DeveloperToolPreviewItem(
                id: "docker-images",
                tool: .docker,
                title: "Images",
                reclaimableBytes: 2_000_000_000,
                commandPreview: ["docker", "system", "df"]
            ),
        ])
        let after = preview(tool: .docker, items: [
            DeveloperToolPreviewItem(
                id: "docker-images",
                tool: .docker,
                title: "Images",
                reclaimableBytes: 200_000_000,
                commandPreview: ["docker", "system", "df"]
            ),
        ])
        let initial: DeveloperToolsView.Phase = .ready(
            availabilities: [availability(.docker, installed: true)],
            previews: [.docker: .loaded(before)]
        )

        let next = DeveloperToolsView.applyPreviewResult(
            tool: .docker,
            result: .success(after),
            to: initial
        )

        guard case .ready(_, let previews) = next,
              case .loaded(let loaded) = previews[.docker] else {
            Issue.record("expected refreshed loaded preview, got \(next)")
            return
        }
        #expect(loaded.reclaimableBytes == 200_000_000)
    }

    @Test("Failure result carries a human-readable message")
    func failureCarriesMessage() {
        let initial = DeveloperToolsView.deriveInitialPhase(availabilities: [
            availability(.docker, installed: true),
        ])
        let error = DeveloperToolPreviewError.commandFailed(
            tool: .docker,
            exitCode: 1,
            stderr: "cannot connect to the Docker daemon"
        )

        let next = DeveloperToolsView.applyPreviewResult(
            tool: .docker,
            result: .failure(error),
            to: initial
        )

        guard case .ready(_, let previews) = next else {
            Issue.record("expected .ready, got \(next)")
            return
        }
        guard case .failed(let message) = previews[.docker] else {
            Issue.record("expected .failed, got \(String(describing: previews[.docker]))")
            return
        }
        #expect(message.contains("Docker"))
        #expect(message.contains("cannot connect"))
    }

    @Test("Daemon-not-running error maps to .daemonStopped, not .failed")
    func daemonNotRunningMapsToDaemonStopped() {
        let initial = DeveloperToolsView.deriveInitialPhase(availabilities: [
            availability(.docker, installed: true),
        ])
        let error = DeveloperToolPreviewError.daemonNotRunning(.docker)

        let next = DeveloperToolsView.applyPreviewResult(
            tool: .docker,
            result: .failure(error),
            to: initial
        )

        guard case .ready(_, let previews) = next else {
            Issue.record("expected .ready, got \(next)")
            return
        }
        #expect(previews[.docker] == .daemonStopped(.docker))
    }

    @Test("Preview result on .empty phase is ignored — view has moved past it")
    func resultIgnoredOnEmpty() {
        let phase: DeveloperToolsView.Phase = .empty(availabilities: [
            availability(.homebrew, installed: false),
        ])
        let next = DeveloperToolsView.applyPreviewResult(
            tool: .homebrew,
            result: .success(preview(tool: .homebrew)),
            to: phase
        )
        #expect(next == phase)
    }

    @Test("Preview result on .loading phase is ignored until availabilities resolve")
    func resultIgnoredOnLoading() {
        let phase: DeveloperToolsView.Phase = .loading
        let next = DeveloperToolsView.applyPreviewResult(
            tool: .docker,
            result: .success(preview(tool: .docker)),
            to: phase
        )
        #expect(next == phase)
    }

    @Test("Multi-word Docker types round-trip through preview state")
    func dockerBuildCachePreserved() {
        let initial = DeveloperToolsView.deriveInitialPhase(availabilities: [
            availability(.docker, installed: true),
        ])
        let dockerPreview = preview(tool: .docker, items: [
            DeveloperToolPreviewItem(
                id: "docker-build-cache",
                tool: .docker,
                title: "Build Cache",
                detail: "Build Cache 0 0 0B 0B",
                reclaimableBytes: 0,
                commandPreview: ["docker", "system", "df"]
            ),
        ])

        let next = DeveloperToolsView.applyPreviewResult(
            tool: .docker,
            result: .success(dockerPreview),
            to: initial
        )

        guard case .ready(_, let previews) = next,
              case .loaded(let loaded) = previews[.docker] else {
            Issue.record("expected loaded docker preview, got \(next)")
            return
        }
        #expect(loaded.items.first?.title == "Build Cache")
    }
}
