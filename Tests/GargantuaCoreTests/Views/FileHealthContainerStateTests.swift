import Foundation
import Testing
@testable import GargantuaCore

// MARK: - Fixture

private func makeResult(category: CzkawkaCategory = .emptyFiles) -> ScanResult {
    let entry = CzkawkaTrustDefaults.builtIn.entry(for: category)
    return ScanResult(
        id: "test-\(category.rawValue)",
        name: "fixture",
        path: "/tmp/fixture",
        size: 128,
        safety: entry.safety,
        confidence: entry.confidence,
        explanation: entry.explanation,
        source: SourceAttribution(name: "Czkawka"),
        category: category.resultCategory,
        tags: []
    )
}

// MARK: - FileHealthContainerState.finishScan

@Suite("FileHealthContainerState.finishScan")
@MainActor
struct FileHealthContainerStateTests {

    @Test("Results with no errors yield results phase with no warnings")
    func cleanResults() {
        let state = FileHealthContainerState()
        state.finishScan(results: [makeResult()], errors: [])
        #expect(state.phase == .results)
        #expect(state.scanResults.count == 1)
        #expect(state.scanWarnings.isEmpty)
    }

    @Test("Results with errors stay in results phase and carry warnings")
    func partialFailureSurfacesWarnings() {
        let state = FileHealthContainerState()
        state.finishScan(
            results: [makeResult()],
            errors: [
                "czkawka_cli image exit 1: ffprobe not found",
                "czkawka_cli broken exit 1: permission denied",
            ]
        )
        #expect(state.phase == .results)
        #expect(state.scanResults.count == 1)
        #expect(state.scanWarnings.count == 2)
        #expect(state.scanWarnings.contains { $0.contains("ffprobe") })
    }

    @Test("No results + errors collapses to error phase")
    func allCategoriesFailed() {
        let state = FileHealthContainerState()
        state.finishScan(results: [], errors: ["czkawka_cli empty-files exit 2: invalid arg"])
        #expect(state.phase == .error)
        #expect(state.errorMessage?.contains("empty-files") == true)
    }

    @Test("No results + no errors yields results phase (czkawka ran cleanly, found nothing)")
    func cleanBillOfHealth() {
        let state = FileHealthContainerState()
        state.finishScan(results: [], errors: [])
        #expect(state.phase == .results)
        #expect(state.scanResults.isEmpty)
        #expect(state.scanWarnings.isEmpty)
    }
}
