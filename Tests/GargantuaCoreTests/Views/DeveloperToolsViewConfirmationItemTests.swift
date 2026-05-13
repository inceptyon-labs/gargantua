import Foundation
import Testing
@testable import GargantuaCore

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

@Suite("DeveloperToolsView confirmation items")
struct DeveloperToolsViewConfirmationItemTests {

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

    @Test("Xcode confirmation uses simctl preview bytes when available")
    func xcodeConfirmationUsesPreviewBytes() {
        let xcode = preview(tool: .xcode, items: [
            DeveloperToolPreviewItem(
                id: "xcode-simulator-AAAA",
                tool: .xcode,
                title: "iPhone 14",
                reclaimableBytes: 12_000_000,
                commandPreview: ["xcrun", "simctl", "list", "-j", "devices", "unavailable"]
            ),
        ])

        let item = DeveloperToolsView.confirmationItem(for: DeveloperToolsView.ExecutionRequest(
            operation: .xcodeDeleteUnavailableSimulators,
            preview: xcode
        ))

        #expect(item.path == "xcrun simctl delete unavailable")
        #expect(item.size == 12_000_000)
        #expect(item.source.name == "Xcode Simulator")
    }

    @Test("Go module cache confirmation carries offline risk copy")
    func goModuleConfirmationCarriesRiskCopy() {
        let go = preview(tool: .go, items: [
            DeveloperToolPreviewItem(
                id: "go-module-cache",
                tool: .go,
                title: "Go module download cache",
                reclaimableBytes: 24_000,
                commandPreview: ["go", "env", "-json", "GOCACHE", "GOMODCACHE"]
            ),
        ])

        let item = DeveloperToolsView.confirmationItem(for: DeveloperToolsView.ExecutionRequest(
            operation: .goCleanModcache,
            preview: go
        ))

        #expect(item.path == "go clean -modcache")
        #expect(item.size == 24_000)
        #expect(item.explanation.contains("network access"))
        #expect(!item.explanation.contains("exact reclaim estimate"))
    }

    @Test("pnpm zero estimate is explicit instead of unavailable")
    func pnpmZeroEstimateIsExplicit() {
        let pnpm = preview(tool: .pnpm, items: [
            DeveloperToolPreviewItem(
                id: "pnpm-store",
                tool: .pnpm,
                title: "pnpm content-addressable store",
                reclaimableBytes: 0,
                commandPreview: ["pnpm", "store", "path"]
            ),
        ])

        let item = DeveloperToolsView.confirmationItem(for: DeveloperToolsView.ExecutionRequest(
            operation: .pnpmStorePrune,
            preview: pnpm
        ))

        #expect(item.path == "pnpm store prune")
        #expect(item.size == 0)
        #expect(!item.explanation.contains("exact reclaim estimate"))
    }

    @Test("Cargo cache confirmation uses preview bytes and review copy")
    func cargoConfirmationUsesPreviewBytes() {
        let cargo = preview(tool: .cargo, items: [
            DeveloperToolPreviewItem(
                id: "cargo-registry-src",
                tool: .cargo,
                title: "Cargo extracted registry sources",
                reclaimableBytes: 12_000_000,
                commandPreview: ["cargo", "--version"]
            ),
        ])

        let item = DeveloperToolsView.confirmationItem(for: DeveloperToolsView.ExecutionRequest(
            operation: .cargoPurgeExtractedCaches,
            preview: cargo
        ))

        #expect(item.path == "cargo cache purge-extracted")
        #expect(item.size == 12_000_000)
        #expect(item.source.name == "Cargo")
        #expect(item.explanation.contains("recreate"))
    }
}
