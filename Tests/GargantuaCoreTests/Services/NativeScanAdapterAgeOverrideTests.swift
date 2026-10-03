import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@Suite("NativeScanAdapter age overrides on folders")
struct NativeScanAdapterAgeOverrideTests {
    @Test("A folder whose own dates are old but whose contents changed recently is not promoted")
    func folderJudgedByNewestChild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("age-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Local Storage", isDirectory: true)
        let leveldb = storage.appendingPathComponent("leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: leveldb, withIntermediateDirectories: true)
        try Data("live".utf8).write(to: leveldb.appendingPathComponent("000001.log"))
        // The folder's own access and modification dates are 200 days old;
        // its leveldb/ child was just written.
        let old = Date().addingTimeInterval(-200 * 86_400).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(old), tv_usec: 0), timeval(tv_sec: Int(old), tv_usec: 0)]
        #expect(utimes(storage.path, &times) == 0)

        let rule = ScanRule(
            id: "local_storage",
            name: "Local Storage",
            paths: [storage.path],
            safety: .review,
            confidence: 70,
            explanation: "site data",
            source: SourceAttribution(name: "test"),
            category: "browser_data",
            safetyOverrides: [SafetyOverride(condition: "age > 90d", safety: .safe, profiles: ["deep"])]
        )

        let results = try await NativeScanAdapter(rules: [rule], profile: .deep).scan()

        #expect(results.map(\.safety) == [.review])
    }
}
