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

// MARK: - deriveScanState

@Suite("FileHealthContainerView.deriveScanState")
struct FileHealthContainerStateTests {

    @Test("Results with no errors yield plain results state")
    func cleanResults() {
        let state = FileHealthContainerView.deriveScanState(
            results: [makeResult()],
            errors: []
        )

        if case .results(let results, let warnings) = state {
            #expect(results.count == 1)
            #expect(warnings.isEmpty)
        } else {
            Issue.record("expected .results, got \(state)")
        }
    }

    @Test("Results with errors carry warnings so the UI can flag partial failure")
    func partialFailureSurfacesWarnings() {
        let state = FileHealthContainerView.deriveScanState(
            results: [makeResult()],
            errors: [
                "czkawka_cli image exit 1: ffprobe not found",
                "czkawka_cli broken exit 1: permission denied",
            ]
        )

        if case .results(let results, let warnings) = state {
            #expect(results.count == 1)
            #expect(warnings.count == 2)
            #expect(warnings.contains { $0.contains("ffprobe") })
        } else {
            Issue.record("expected .results with warnings, got \(state)")
        }
    }

    @Test("No results + errors collapses to terminal error")
    func allCategoriesFailed() {
        let state = FileHealthContainerView.deriveScanState(
            results: [],
            errors: ["czkawka_cli empty-files exit 2: invalid arg"]
        )

        if case .error(let message) = state {
            #expect(message.contains("empty-files"))
        } else {
            Issue.record("expected .error, got \(state)")
        }
    }

    @Test("No results + no errors is still .results (czkawka ran cleanly, found nothing)")
    func cleanBillOfHealth() {
        let state = FileHealthContainerView.deriveScanState(results: [], errors: [])

        if case .results(let results, let warnings) = state {
            #expect(results.isEmpty)
            #expect(warnings.isEmpty)
        } else {
            Issue.record("expected empty .results, got \(state)")
        }
    }
}
