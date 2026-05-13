import Foundation
import Testing
@testable import GargantuaCore

@Suite("DeveloperToolsView success messages")
struct DeveloperToolsViewSuccessMessageTests {

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
