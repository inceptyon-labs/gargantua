import Foundation
import Testing
@testable import GargantuaCore

@Suite("CleanupResult")
struct CleanupResultTests {
    func makeItem(
        id: String = "test",
        path: String? = nil,
        size: Int64 = 1000,
        safety: SafetyLevel = .safe
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: "Test Item \(id)",
            path: path ?? "/tmp/test/\(id)",
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "Test item",
            source: SourceAttribution(name: "Test"),
            category: "test"
        )
    }

    /// Captures the file-system fixture produced by `makeFakeTrash`.
    struct FakeTrash {
        let home: URL
        let trash: URL
        let totalBytes: Int64
    }

    /// Build a fake home directory with a `.Trash` subdirectory populated
    /// by `children`. Returns the fixture for assertions and cleanup.
    @discardableResult
    func makeFakeTrash(children: [String: Data]) throws -> FakeTrash {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-trash-test-\(UUID().uuidString)", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var total: Int64 = 0
        for (name, data) in children {
            try data.write(to: trash.appendingPathComponent(name))
            total += Int64(data.count)
        }
        return FakeTrash(home: home, trash: trash, totalBytes: total)
    }
}

@MainActor
final class RecordingTrashMover: TrashMoving {
    enum Outcome {
        case success(URL?)
        case failure(String)
    }

    private let outcome: Outcome
    private(set) var movedURLs: [URL] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func moveToTrash(_ url: URL) async throws -> URL? {
        movedURLs.append(url)
        switch outcome {
        case .success(let trashURL):
            return trashURL
        case .failure(let message):
            throw TrashMoveFailure(message: message)
        }
    }
}
