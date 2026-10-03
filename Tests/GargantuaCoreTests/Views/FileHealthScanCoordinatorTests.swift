import Foundation
import Testing
@testable import GargantuaCore

@Suite("FileHealthScanCoordinator")
@MainActor
struct FileHealthScanCoordinatorTests {
    @Test("startScan publishes results and warnings from the adapter")
    func startScanPublishesResultsAndWarnings() async throws {
        let state = FileHealthContainerState()
        let coordinator = FileHealthScanCoordinator()
        let roots = [URL(fileURLWithPath: "/tmp/file-health-root")]
        let result = Self.makeResult(id: "empty-file")
        var capturedRoots: [URL] = []

        coordinator.startScan(
            state: state,
            scanRoots: roots,
            profile: .deep,
            engineFactory: { scanRoots, _ in
                capturedRoots = scanRoots
                return StubAdapter(results: [result], warnings: ["partial czkawka warning"])
            }
        )

        try await waitForPhase(.results, state: state)

        #expect(capturedRoots == roots)
        #expect(state.scanResults.map(\.id) == ["empty-file"])
        #expect(state.scanWarnings == ["partial czkawka warning"])
    }

    @Test("cancelling a running scan returns to idle instead of staying on the scanning screen")
    func cancelReturnsToIdle() async throws {
        let state = FileHealthContainerState()
        let coordinator = FileHealthScanCoordinator()

        coordinator.startScan(
            state: state,
            scanRoots: [URL(fileURLWithPath: "/tmp/file-health-root")],
            profile: .deep,
            engineFactory: { _, _ in HangingAdapter() }
        )
        #expect(state.phase == .scanning)

        coordinator.cancelActiveScan(state: state)

        #expect(state.phase == .idle)
    }

    private struct HangingAdapter: ScanAdapter {
        func scan(progress: ScanProgress?) async throws -> [ScanResult] {
            try await Task.sleep(for: .seconds(60))
            return []
        }
    }

    private final class StubAdapter: ScanAdapter, @unchecked Sendable {
        let results: [ScanResult]
        let warnings: [String]

        init(results: [ScanResult], warnings: [String]) {
            self.results = results
            self.warnings = warnings
        }

        func scan(progress: ScanProgress?) async throws -> [ScanResult] {
            await MainActor.run {
                warnings.forEach { progress?.recordError($0) }
            }
            return results
        }
    }

    private static func makeResult(id: String) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: 1,
            safety: .review,
            confidence: 90,
            explanation: "test",
            source: SourceAttribution(name: "FileHealthScanCoordinatorTests"),
            category: CzkawkaCategory.emptyFiles.resultCategory,
            tags: []
        )
    }

    private func waitForPhase(
        _ phase: FileHealthPhase,
        state: FileHealthContainerState
    ) async throws {
        for _ in 0 ..< 100 {
            if state.phase == phase { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(state.phase == phase)
    }
}
