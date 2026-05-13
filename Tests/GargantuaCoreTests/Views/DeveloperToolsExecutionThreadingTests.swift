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

@Suite("DeveloperToolsView execution threading and operation gating")
struct DeveloperToolsExecutionThreadingTests {
    enum ThreadProbeError: Error {
        case ranOnMainThread
    }

    @Test("subprocess-backed providers run away from the main thread")
    @MainActor
    func subprocessProvidersRunOffMainThread() async {
        let availabilities = await DeveloperToolsView.runAvailabilityProviderOffMain {
            [
                availability(.homebrew, installed: !Thread.isMainThread),
            ]
        }

        #expect(availabilities.first?.isInstalled == true)

        let previewResult = await DeveloperToolsView.runPreviewProviderOffMain({ tool in
            if Thread.isMainThread { throw ThreadProbeError.ranOnMainThread }
            return preview(tool: tool)
        }, tool: .homebrew)

        guard case .success(let loadedPreview) = previewResult else {
            Issue.record("expected preview provider to run off the main thread")
            return
        }
        #expect(loadedPreview.tool == .homebrew)

        let executionResult = await DeveloperToolsView.runExecutionProviderOffMain(
            { operation, preview, _ in
                if Thread.isMainThread { throw ThreadProbeError.ranOnMainThread }
                return DeveloperToolExecutionResult(
                    operation: operation,
                    commandPreview: operation.commandPreview(executable: URL(fileURLWithPath: "/usr/local/bin/brew")),
                    output: ProcessOutput(stdout: "", stderr: "", exitCode: 0),
                    estimatedBytesFreed: operation.estimatedReclaimableBytes(in: preview) ?? 0
                )
            },
            operation: .homebrewCleanup,
            preview: loadedPreview,
            confirmationMethod: .summaryDialog
        )

        guard case .success(let result) = executionResult else {
            Issue.record("expected execution provider to run off the main thread")
            return
        }
        #expect(result.operation == .homebrewCleanup)
    }

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

    @Test("command-action tools expose their fixed operations from read-only previews")
    func promotedCommandActionToolsExposeOperations() {
        let xcode = preview(tool: .xcode, items: [
            DeveloperToolPreviewItem(
                id: "xcode-simulator-AAAA",
                tool: .xcode,
                title: "iPhone 14",
                reclaimableBytes: 12_000_000,
                commandPreview: ["xcrun", "simctl", "list", "-j", "devices", "unavailable"]
            ),
        ])
        let pnpm = preview(tool: .pnpm, items: [
            DeveloperToolPreviewItem(
                id: "pnpm-store",
                tool: .pnpm,
                title: "pnpm content-addressable store",
                commandPreview: ["pnpm", "store", "path"]
            ),
        ])
        let go = preview(tool: .go, items: [
            DeveloperToolPreviewItem(
                id: "go-build-cache",
                tool: .go,
                title: "Go build cache",
                commandPreview: ["go", "env", "-json", "GOCACHE", "GOMODCACHE"]
            ),
            DeveloperToolPreviewItem(
                id: "go-module-cache",
                tool: .go,
                title: "Go module download cache",
                commandPreview: ["go", "env", "-json", "GOCACHE", "GOMODCACHE"]
            ),
        ])
        let cargo = preview(tool: .cargo, items: [
            DeveloperToolPreviewItem(
                id: "cargo-registry-src",
                tool: .cargo,
                title: "Cargo extracted registry sources",
                reclaimableBytes: 12_000_000,
                commandPreview: ["cargo", "--version"]
            ),
        ])

        #expect(DeveloperToolsView.operations(for: xcode) == [.xcodeDeleteUnavailableSimulators])
        #expect(DeveloperToolsView.operations(for: pnpm) == [.pnpmStorePrune])
        #expect(DeveloperToolsView.operations(for: go) == [.goCleanCache, .goCleanModcache])
        #expect(DeveloperToolsView.operations(for: cargo) == [.cargoPurgeExtractedCaches])
    }
}
