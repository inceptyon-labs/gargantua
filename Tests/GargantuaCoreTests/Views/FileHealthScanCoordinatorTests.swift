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
