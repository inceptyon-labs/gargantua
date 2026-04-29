import Foundation
import Testing
@testable import GargantuaCore

@Suite("CleanupNarrative template")
struct CleanupNarrativeTemplateTests {

    private func makeScanResult(
        id: String,
        name: String,
        size: Int64
    ) -> ScanResult {
        ScanResult(
            id: id,
            name: name,
            path: "/Users/test/Library/Caches/\(id)",
            size: size,
            safety: .safe,
            confidence: 95,
            explanation: "Test item",
            source: SourceAttribution(name: "TestApp"),
            category: "test_category"
        )
    }

    private func makeItem(
        id: String,
        name: String,
        size: Int64,
        succeeded: Bool,
        error: String? = nil
    ) -> CleanupItemResult {
        CleanupItemResult(
            item: makeScanResult(id: id, name: name, size: size),
            succeeded: succeeded,
            trashURL: succeeded ? URL(fileURLWithPath: "/tmp/\(id)") : nil,
            error: succeeded ? nil : (error ?? "boom")
        )
    }

    // MARK: - Structural

    @Test("Empty result renders a sensible nothing-cleaned sentence")
    func emptyResult() {
        let narrative = CleanupNarrativeTemplate.text(
            for: CleanupResult(itemResults: [])
        )

        #expect(!narrative.isEmpty)
        #expect(narrative.lowercased().contains("nothing"))
    }

    @Test("All-failed result renders a nothing-cleaned sentence, not an empty block")
    func allFailed() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "a", name: "Chrome Cache", size: 1_000, succeeded: false),
            makeItem(id: "b", name: "Chrome Cache", size: 2_000, succeeded: false),
        ])

        let narrative = CleanupNarrativeTemplate.text(for: result)

        #expect(!narrative.isEmpty)
        #expect(narrative.lowercased().contains("could not"))
    }

    @Test("Trash method narrative uses 'Trash' verb")
    func trashMethod() {
        let result = CleanupResult(
            itemResults: [makeItem(id: "a", name: "Xcode sims", size: 8_000_000_000, succeeded: true)],
            cleanupMethod: .trash
        )

        let narrative = CleanupNarrativeTemplate.text(for: result)

        #expect(narrative.contains("Trash"))
        #expect(!narrative.lowercased().contains("deleted"))
    }

    @Test("Delete method narrative uses 'Deleted' verb")
    func deleteMethod() {
        let result = CleanupResult(
            itemResults: [makeItem(id: "a", name: "Old logs", size: 500, succeeded: true)],
            cleanupMethod: .delete
        )

        let narrative = CleanupNarrativeTemplate.text(for: result)

        #expect(narrative.contains("Deleted"))
        #expect(!narrative.contains("Trash"))
    }

    @Test("Mixed result narrative mentions both the succeeded count and failure count")
    func partialCleanup() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "a", name: "Chrome Cache", size: 10_000_000, succeeded: true),
            makeItem(id: "b", name: "Chrome Cache", size: 20_000_000, succeeded: true),
            makeItem(id: "c", name: "Locked file", size: 500, succeeded: false, error: "perm"),
        ])

        let narrative = CleanupNarrativeTemplate.text(for: result)

        #expect(narrative.contains("2"))
        #expect(narrative.contains("1"))
        #expect(narrative.lowercased().contains("could not"))
    }

    @Test("Top groups appear in the narrative when multiple items share a name")
    func topGroupsCallout() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "c1", name: "Chrome Cache", size: 5_000_000, succeeded: true),
            makeItem(id: "c2", name: "Chrome Cache", size: 5_000_000, succeeded: true),
            makeItem(id: "x1", name: "Xcode DerivedData", size: 1_000_000, succeeded: true),
            makeItem(id: "x2", name: "Xcode DerivedData", size: 1_000_000, succeeded: true),
        ])

        let narrative = CleanupNarrativeTemplate.text(for: result)

        #expect(narrative.contains("Chrome Cache"))
        #expect(narrative.contains("Xcode DerivedData"))
    }

    @Test("Singleton groups never appear as narrative callouts (PII tightening)")
    func singletonGroupsSuppressed() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "s1", name: "MyPrivateProject", size: 1_000, succeeded: true),
            makeItem(id: "s2", name: "SecretApp-Cache", size: 2_000, succeeded: true),
            makeItem(id: "s3", name: "Other-Thing", size: 3_000, succeeded: true),
        ])

        let narrative = CleanupNarrativeTemplate.text(for: result)

        // Each item has a unique name (count == 1). The narrative should
        // summarize the aggregate only — never surface singleton item names,
        // even though they are technically present in CleanupResult.
        #expect(!narrative.contains("MyPrivateProject"))
        #expect(!narrative.contains("SecretApp-Cache"))
        #expect(!narrative.contains("Other-Thing"))
        // Sanity: aggregate headline is still present.
        #expect(narrative.contains("3"))
    }

    // MARK: - PII safety

    @Test("Narrative contains no substring outside the fields on CleanupResult")
    func noPIIBeyondResultFields() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "a", name: "Chrome Cache", size: 1_048_576, succeeded: true),
            makeItem(id: "b", name: "Xcode DerivedData", size: 2_097_152, succeeded: true),
            makeItem(id: "c", name: "Locked File", size: 100, succeeded: false, error: "permission denied"),
        ])

        let narrative = CleanupNarrativeTemplate.text(for: result)

        // Anything that looks like a filesystem path (which `ScanResult.path`
        // carries but the narrative should not surface) is a red flag.
        #expect(!narrative.contains("/Users/"))
        #expect(!narrative.contains("/tmp/"))
        #expect(!narrative.contains("/Library/"))

        // Raw scan ids are internal identifiers, not user-facing names.
        #expect(!narrative.contains("chrome_cache"))
        #expect(!narrative.contains("test_category"))

        // Error strings from individual CleanupItemResults are not narrated
        // (the structured list already shows them — the narrative stays
        // high-level).
        #expect(!narrative.contains("permission denied"))
    }

    @Test("Single-item narrative does not repeat the same name twice as a group")
    func singleItemNoGroup() {
        let result = CleanupResult(itemResults: [
            makeItem(id: "only", name: "SolitaryItem", size: 1_000, succeeded: true),
        ])

        let narrative = CleanupNarrativeTemplate.text(for: result)

        // "SolitaryItem" would redundantly appear as both the only item and
        // the only "group" if we didn't suppress singletons — the template
        // should call it a freed-bytes headline, not a "group" callout.
        let occurrences = narrative.components(separatedBy: "SolitaryItem").count - 1
        #expect(occurrences == 0)
    }
}

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

@Suite("AIInferenceEngine narrate default")
@MainActor
struct AIInferenceEngineNarrateDefaultTests {

    @Test("Default implementation returns the deterministic template text")
    func defaultFallsBackToTemplate() async throws {
        let engine = NarrateFakeEngineNoOverride()
        let result = CleanupResult(itemResults: [
            CleanupItemResult(
                item: ScanResult(
                    id: "a",
                    name: "Chrome Cache",
                    path: "/Users/test/Library/Caches/Chrome",
                    size: 1_000,
                    safety: .safe,
                    confidence: 95,
                    explanation: "Test",
                    source: SourceAttribution(name: "Test"),
                    category: "test"
                ),
                succeeded: true,
                trashURL: URL(fileURLWithPath: "/tmp/a")
            ),
        ])

        let text = try await engine.narrate(cleanup: result)
        #expect(text == CleanupNarrativeTemplate.text(for: result))
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

/// Engine that inherits the default `narrate` extension — used to pin the
/// default-implementation behavior.
@MainActor
private final class NarrateFakeEngineNoOverride: AIInferenceEngine {
    let kind: AIEnginePreference = .mlx
    private(set) var isLoaded: Bool = false
    private(set) var memoryUsage: Int64 = 0

    func load(modelPath: String, modelSize: Int64) async throws {
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
}
