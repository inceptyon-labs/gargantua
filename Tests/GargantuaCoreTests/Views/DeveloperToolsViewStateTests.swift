import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Fixtures

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

// MARK: - deriveInitialPhase

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

// MARK: - applyPreviewResult

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

// MARK: - execution operations

@Suite("DeveloperToolsView execution flow helpers")
struct DeveloperToolsViewExecutionFlowTests {

    @Test("operations are gated by loaded preview applicability")
    func operationsArePreviewGated() {
        let docker = preview(tool: .docker, items: [
            DeveloperToolPreviewItem(
                id: "docker-images",
                tool: .docker,
                title: "Images",
                reclaimableBytes: 10,
                commandPreview: ["docker", "system", "df"]
            ),
            DeveloperToolPreviewItem(
                id: "docker-build-cache",
                tool: .docker,
                title: "Build Cache",
                reclaimableBytes: 0,
                commandPreview: ["docker", "system", "df"]
            ),
        ])

        let operations = DeveloperToolsView.operations(for: docker)

        #expect(operations.contains(.dockerImagePrune))
        #expect(operations.contains(.dockerSystemPrune))
        #expect(!operations.contains(.dockerBuilderPrune))
        #expect(!operations.contains(.homebrewCleanup))
    }

    @Test("confirmation item tier matches operation safety")
    func confirmationItemTierMatchesSafety() {
        let docker = preview(tool: .docker, items: [
            DeveloperToolPreviewItem(
                id: "docker-volumes",
                tool: .docker,
                title: "Local Volumes",
                reclaimableBytes: 100,
                commandPreview: ["docker", "system", "df"]
            ),
        ])
        let protectedRequest = DeveloperToolsView.ExecutionRequest(
            operation: .dockerVolumePrune,
            preview: docker
        )
        let reviewRequest = DeveloperToolsView.ExecutionRequest(
            operation: .dockerImagePrune,
            preview: docker
        )

        #expect(confirmationTier(for: [DeveloperToolsView.confirmationItem(for: protectedRequest)]) == .fullModal)
        #expect(confirmationTier(for: [DeveloperToolsView.confirmationItem(for: reviewRequest)]) == .summaryDialog)
    }

    @Test("protected confirmation item explains what Docker data can be lost")
    func protectedConfirmationItemCarriesRiskCopy() {
        let docker = preview(tool: .docker, items: [
            DeveloperToolPreviewItem(
                id: "docker-volumes",
                tool: .docker,
                title: "Local Volumes",
                reclaimableBytes: 100,
                commandPreview: ["docker", "system", "df"]
            ),
        ])

        let item = DeveloperToolsView.confirmationItem(for: DeveloperToolsView.ExecutionRequest(
            operation: .dockerVolumePrune,
            preview: docker
        ))

        #expect(item.safety == .protected_)
        #expect(item.size == 100)
        #expect(item.explanation.contains("databases"))
        #expect(item.explanation.contains("cannot be rebuilt"))
    }

    @Test("unknown-estimate operations do not borrow unrelated preview bytes")
    func unknownEstimateConfirmationItemUsesZero() {
        let brew = preview(tool: .homebrew, items: [
            DeveloperToolPreviewItem(
                id: "homebrew-0",
                tool: .homebrew,
                title: "Would remove foo",
                reclaimableBytes: 12_000_000,
                commandPreview: ["brew", "cleanup", "-n"]
            ),
        ])

        let item = DeveloperToolsView.confirmationItem(for: DeveloperToolsView.ExecutionRequest(
            operation: .homebrewAutoremove,
            preview: brew
        ))

        #expect(item.size == 0)
        #expect(item.explanation.contains("does not report an exact reclaim estimate"))
    }

    @Test("success message reports post-run preview delta")
    func successMessageReportsDelta() {
        let message = DeveloperToolsView.successMessage(
            operation: .dockerImagePrune,
            beforeBytes: 2_000_000_000,
            afterBytes: 500_000_000
        )

        #expect(message.contains("Prune dangling images completed"))
        #expect(message.contains("1.5 GB"))
    }

    @Test("success message explains unknown and unchanged estimates")
    func successMessageExplainsUnknownEstimates() {
        let unknown = DeveloperToolsView.successMessage(
            operation: .homebrewAutoremove,
            beforeBytes: nil,
            afterBytes: nil
        )
        let unchanged = DeveloperToolsView.successMessage(
            operation: .dockerBuilderPrune,
            beforeBytes: 500,
            afterBytes: 500
        )

        #expect(unknown.contains("exact reclaimed bytes are unavailable"))
        #expect(unchanged.contains("no reclaimable decrease"))
    }
}

// MARK: - Sidebar wiring

@Suite("Developer Tools sidebar wiring")
struct DeveloperToolsSidebarTests {

    @Test("TOOLS section includes devTools entry")
    func toolsSectionHasDevTools() {
        let tools = SidebarSection.defaultSections.first { $0.id == "tools" }
        let ids = tools?.items.map(\.id) ?? []
        #expect(ids.contains("devTools"))
    }

    @Test("devTools label is user-facing")
    func devToolsLabel() {
        let item = SidebarSection.defaultSections
            .flatMap(\.items)
            .first { $0.id == "devTools" }
        #expect(item?.label == "Developer Tools")
        let icon = item?.icon ?? ""
        #expect(icon.isEmpty == false)
    }
}
