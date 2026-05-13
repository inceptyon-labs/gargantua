import Foundation
import Testing
@testable import GargantuaCore

@MainActor
private func makeNeverDownloadedManager() -> ModelDownloadManager {
    let info = ModelInfo(
        id: "test-never-\(UUID().uuidString)",
        name: "Unstaged test model",
        files: [
            ModelFile(
                name: "placeholder",
                url: URL(string: "https://example.invalid/x")!,
                sha256: "0000000000000000000000000000000000000000000000000000000000000000",
                size: 1
            ),
        ]
    )
    return ModelDownloadManager(modelInfo: info)
}

@Suite("LocalAIService scan filter routing")
@MainActor
struct LocalAIServiceScanFilterTests {

    @Test("scan filter asks injected engine even when no model is downloaded")
    func scanFilterUsesInjectedEngineWithoutModel() async throws {
        let manager = makeNeverDownloadedManager()
        let filter = ScanFilterSet(categories: ["dev_artifacts"], safetyLevels: [.review])
        let engine = FakeScanFilterEngine(scanFilter: filter)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let resolved = try await service.scanFilter(for: "show me everything related to Xcode")

        #expect(resolved == filter)
        #expect(engine.scanFilterCallCount == 1)
        #expect(engine.loadCallCount == 0)
    }

    @Test("scan filter returns nil on engine failure")
    func scanFilterFailureFallsBackToNil() async throws {
        let manager = makeNeverDownloadedManager()
        let engine = FakeScanFilterEngine(scanFilterError: FakeScanFilterError.boom)
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let resolved = try await service.scanFilter(for: "unparseable")

        #expect(resolved == nil)
    }

    @Test("TemplateInferenceEngine maps Xcode query to scan filter")
    func templateEngineMapsXcodeQueryToFilter() async throws {
        let engine = TemplateInferenceEngine()

        let filter = try #require(try await engine.scanFilter(for: "Show me everything related to Xcode"))

        #expect(filter.bundleIDs.contains("com.apple.dt.Xcode"))
        #expect(filter.categories.contains("dev_artifacts"))
        #expect(filter.pathGlobs.contains(where: { $0.localizedCaseInsensitiveContains("Xcode") }))
    }
}

// MARK: - Test doubles

private enum FakeScanFilterError: Error { case boom }

@MainActor
private final class FakeScanFilterEngine: AIInferenceEngine {
    let kind: AIEnginePreference = .mlx
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    private(set) var loadCallCount = 0
    private(set) var scanFilterCallCount = 0

    private let scanFilterResult: ScanFilterSet?
    private let scanFilterError: Error?

    init(scanFilter: ScanFilterSet? = nil, scanFilterError: Error? = nil) {
        self.scanFilterResult = scanFilter
        self.scanFilterError = scanFilterError
    }

    func load(modelPath: String, modelSize: Int64) async throws {
        loadCallCount += 1
        isLoaded = true
        memoryUsage = modelSize
    }

    func unload() {
        isLoaded = false
        memoryUsage = 0
    }

    func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        ""
    }

    func scanFilter(for query: String) async throws -> ScanFilterSet? {
        scanFilterCallCount += 1
        if let scanFilterError {
            throw scanFilterError
        }
        return scanFilterResult
    }
}
