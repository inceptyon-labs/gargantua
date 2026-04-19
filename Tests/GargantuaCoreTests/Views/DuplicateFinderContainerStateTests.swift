import Foundation
import Testing
@testable import GargantuaCore

@Suite("DuplicateFinderContainerView state derivation")
struct DuplicateFinderContainerStateTests {

    private static func makeResult(id: String) -> ScanResult {
        ScanResult(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            size: 1,
            safety: .review,
            confidence: 50,
            explanation: "test",
            source: SourceAttribution(name: "DuplicateFinderContainerStateTests"),
            category: "duplicate_files"
        )
    }

    @Test("Empty results with recorded errors surface as .error — silent fclones failures are visible")
    func emptyResultsPlusErrorsBecomesError() {
        let state = DuplicateFinderContainerView.deriveScanState(
            results: [],
            errors: ["fclones exit 1: timed out"]
        )

        guard case .error(let message) = state else {
            Issue.record("Expected .error, got \(state)")
            return
        }
        #expect(message.contains("timed out"))
    }

    @Test("Empty results with no errors is a legitimate \"no duplicates\" outcome")
    func emptyResultsNoErrorsBecomesResults() {
        let state = DuplicateFinderContainerView.deriveScanState(
            results: [],
            errors: []
        )

        guard case .results(let results) = state else {
            Issue.record("Expected .results, got \(state)")
            return
        }
        #expect(results.isEmpty)
    }

    @Test("Partial success (results + errors) still shows results — non-fatal errors don't block review")
    func partialSuccessBecomesResults() {
        let state = DuplicateFinderContainerView.deriveScanState(
            results: [Self.makeResult(id: "dup1")],
            errors: ["Couldn't read /some/subdir: permission denied"]
        )

        guard case .results(let results) = state else {
            Issue.record("Expected .results, got \(state)")
            return
        }
        #expect(results.count == 1)
        #expect(results.first?.id == "dup1")
    }

    @Test("Multiple errors are joined so the user sees every failure cause")
    func multipleErrorsJoined() {
        let state = DuplicateFinderContainerView.deriveScanState(
            results: [],
            errors: ["timed out", "parse failed"]
        )

        guard case .error(let message) = state else {
            Issue.record("Expected .error, got \(state)")
            return
        }
        #expect(message.contains("timed out"))
        #expect(message.contains("parse failed"))
    }
}
