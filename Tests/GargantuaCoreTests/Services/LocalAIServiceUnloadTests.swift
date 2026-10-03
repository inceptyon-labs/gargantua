import Combine
import Foundation
import Testing
@testable import GargantuaCore

@Suite("LocalAIService unload")
@MainActor
struct LocalAIServiceUnloadTests {
    @Test("Unloading with nothing loaded publishes no change")
    func idleUnloadIsSilent() {
        let info = ModelInfo(
            id: "test-unload-\(UUID().uuidString)",
            name: "Unstaged test model",
            files: [
                ModelFile(
                    name: "placeholder",
                    url: URL(string: "https://example.invalid/x")!,
                    sha256: String(repeating: "0", count: 64),
                    size: 1
                ),
            ]
        )
        let service = LocalAIService(downloadManager: ModelDownloadManager(modelInfo: info))
        var changes = 0
        let subscription = service.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        service.unloadModel()

        #expect(changes == 0)
    }
}
