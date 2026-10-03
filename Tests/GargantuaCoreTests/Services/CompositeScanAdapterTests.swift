import Foundation
import Testing
@testable import GargantuaCore

@Suite("CompositeScanAdapter")
struct CompositeScanAdapterTests {
    private final class RecordingAdapter: ScanAdapter, @unchecked Sendable {
        private(set) var calls = 0
        func scan(progress: ScanProgress?) async throws -> [ScanResult] {
            calls += 1
            return []
        }
    }

    @Test("A cancelled scan skips the remaining best-effort adapters")
    func cancelledScanSkipsBestEffort() async throws {
        let bestEffort = RecordingAdapter()
        let adapter = CompositeScanAdapter(primary: RecordingAdapter(), bestEffort: [bestEffort])

        _ = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.scan(progress: nil)
        }.value

        #expect(bestEffort.calls == 0)
    }
}
