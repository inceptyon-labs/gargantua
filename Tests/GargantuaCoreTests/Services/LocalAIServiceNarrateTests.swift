import Foundation
import Testing
@testable import GargantuaCore

@Suite("LocalAIService narrate")
@MainActor
struct LocalAIServiceNarrateTests {

    // MARK: - Fixtures

    private func makeScanResult(id: String, name: String, size: Int64) -> ScanResult {
        ScanResult(
            id: id,
            name: name,
            path: "/Users/test/\(id)",
            size: size,
            safety: .safe,
            confidence: 95,
            explanation: "Test item",
            source: SourceAttribution(name: "Test"),
            category: "test"
        )
    }

    private func makeItem(id: String, name: String, size: Int64, succeeded: Bool) -> CleanupItemResult {
        CleanupItemResult(
            item: makeScanResult(id: id, name: name, size: size),
            succeeded: succeeded,
            trashURL: succeeded ? URL(fileURLWithPath: "/tmp/\(id)") : nil,
            error: succeeded ? nil : "boom"
        )
    }

    private func makeResult() -> CleanupResult {
        CleanupResult(itemResults: [
            makeItem(id: "a", name: "Chrome Cache", size: 1_000_000, succeeded: true),
            makeItem(id: "b", name: "Chrome Cache", size: 2_000_000, succeeded: true),
        ])
    }

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

    private func makeTempModelFile(contents: String) throws -> (path: String, size: Int64) {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("gargantua-test-model-\(UUID().uuidString).bin")
        try contents.data(using: .utf8)!.write(to: url)
        let size = Int64(contents.utf8.count)
        return (url.path, size)
    }

    // MARK: - Fallback paths

    @Test("No model + Template engine → template narrative with .template source")
    func noModelAvailableUsesTemplateEngine() async {
        let manager = makeNeverDownloadedManager()
        // Default engine is `TemplateInferenceEngine`. It runs without a
        // model now, so the narrative is `.template`-sourced rather than
        // the raw `.rule` fallback this test originally pinned.
        let service = LocalAIService(downloadManager: manager)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .template)
        #expect(narrative.text == CleanupNarrativeTemplate.text(for: makeResult()))
        #expect(!narrative.text.isEmpty)
    }

    @Test("Engine load failure → template narrative with .rule source")
    func loadFailureFallsBackToTemplate() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = NarrateFakeEngine(
            output: "Should never be used",
            loadError: NarrateFakeError.boom
        )
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .rule)
        #expect(narrative.text == CleanupNarrativeTemplate.text(for: makeResult()))
    }

    @Test("Engine narrate failure → template narrative with .rule source (no throw)")
    func engineFailureFallsBackToTemplate() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = NarrateFakeEngine(
            output: "Should never be used",
            narrateError: NarrateFakeError.boom
        )
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .rule)
        #expect(narrative.text == CleanupNarrativeTemplate.text(for: makeResult()))
    }

    // MARK: - AI path

    @Test("Model available + engine succeeds → .ai source and engine text")
    func aiPath() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = NarrateFakeEngine(output: "Cleaned 3 MB — mostly cache.")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .ai)
        #expect(narrative.text == "Cleaned 3 MB — mostly cache.")
    }

    @Test("Empty engine output falls back to template so the UI never renders an empty block")
    func emptyEngineOutputFallsBack() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = NarrateFakeEngine(output: "")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .rule)
        #expect(narrative.text == CleanupNarrativeTemplate.text(for: makeResult()))
    }

    @Test("Whitespace-only engine output falls back to template")
    func whitespaceEngineOutputFallsBack() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = NarrateFakeEngine(output: "   \n  \t")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .rule)
        #expect(narrative.text == CleanupNarrativeTemplate.text(for: makeResult()))
    }

    @Test("Engine text is trimmed of surrounding whitespace when accepted")
    func engineOutputTrimmed() async throws {
        let tmp = try makeTempModelFile(contents: "abc")
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let manager = ModelDownloadManager()
        manager._setStateForTesting(.downloaded(path: tmp.path, size: tmp.size))

        let engine = NarrateFakeEngine(output: "  Cleaned a lot.  \n")
        let service = LocalAIService(downloadManager: manager, engine: engine)

        let narrative = await service.narrate(cleanup: makeResult())

        #expect(narrative.source == .ai)
        #expect(narrative.text == "Cleaned a lot.")
    }
}

// MARK: - Test doubles

private enum NarrateFakeError: Error { case boom }

@MainActor
private final class NarrateFakeEngine: AIInferenceEngine {
    let kind: AIEnginePreference = .mlx
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    private let output: String
    private let loadError: Error?
    private let narrateError: Error?

    init(
        output: String,
        loadError: Error? = nil,
        narrateError: Error? = nil
    ) {
        self.output = output
        self.loadError = loadError
        self.narrateError = narrateError
    }

    func load(modelPath: String, modelSize: Int64) async throws {
        if let loadError { throw loadError }
        isLoaded = true
        memoryUsage = modelSize
    }

    func unload() {
        isLoaded = false
        memoryUsage = 0
    }

    func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        output
    }

    func narrate(cleanup result: CleanupResult) async throws -> String {
        if let narrateError { throw narrateError }
        return output
    }
}
