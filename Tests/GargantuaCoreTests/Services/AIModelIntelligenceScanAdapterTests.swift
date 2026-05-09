import Foundation
import Testing
@testable import GargantuaCore

@Suite("AIModelIntelligenceScanAdapter")
struct AIModelIntelligenceScanAdapterTests {

    @Test("same filename and size across stores becomes review-only duplicate group output")
    func duplicateGroupingAcrossStores() async throws {
        let fixture = try FixtureTree()
        let ollamaRoot = try fixture.makeDir("Ollama/models")
        let downloads = try fixture.makeDir("Downloads")
        try fixture.makeFile("Ollama/models/llama-7b.gguf", byteCount: 256)
        try fixture.makeFile("Downloads/llama-7b.gguf", byteCount: 256)

        let adapter = makeAdapter(
            knownStores: [
                AIModelStoreDefinition(id: "ollama", displayName: "Ollama", roots: [ollamaRoot]),
            ],
            orphanRoots: [downloads]
        )

        let findings = adapter.discoverFindings()
        let results = try await adapter.scan(progress: nil)

        #expect(findings.duplicateGroups.count == 1)
        #expect(findings.orphanCandidates.isEmpty)
        #expect(results.count == 2)
        #expect(Set(results.map(\.safety)) == [.review])
        #expect(results.allSatisfy { $0.tags.contains(AIModelIntelligenceScanAdapter.duplicateTag) })
        #expect(results.allSatisfy { $0.explanation.contains("does not inspect model contents") })
        #expect(results.contains { $0.source.name == "Ollama" })
        #expect(results.contains { $0.source.name == "Orphan model file" })
    }

    @Test("orphan scan honors minimum size and supported model extensions")
    func orphanThresholdsAndExtensions() async throws {
        let fixture = try FixtureTree()
        let downloads = try fixture.makeDir("Downloads")
        try fixture.makeFile("Downloads/tiny.gguf", byteCount: 64)
        try fixture.makeFile("Downloads/readme.txt", byteCount: 512)
        try fixture.makeFile("Downloads/forgotten-model.pth", byteCount: 512)

        let adapter = makeAdapter(knownStores: [], orphanRoots: [downloads])
        let results = try await adapter.scan(progress: nil)

        #expect(results.map(\.name) == ["Orphan model weight — forgotten-model.pth"])
        #expect(results.first?.safety == .review)
        #expect(results.first?.tags.contains(AIModelIntelligenceScanAdapter.orphanTag) == true)
    }

    @Test("known store files are not emitted as orphan candidates")
    func knownStoresAreExcludedFromOrphans() async throws {
        let fixture = try FixtureTree()
        let downloads = try fixture.makeDir("Downloads")
        let comfyRoot = try fixture.makeDir("Downloads/ComfyUI/models")
        try fixture.makeFile("Downloads/ComfyUI/models/sdxl.safetensors", byteCount: 512)

        let adapter = makeAdapter(
            knownStores: [
                AIModelStoreDefinition(id: "comfyui", displayName: "ComfyUI", roots: [comfyRoot]),
            ],
            orphanRoots: [downloads]
        )

        let findings = adapter.discoverFindings()
        let results = try await adapter.scan(progress: nil)

        #expect(findings.duplicateGroups.isEmpty)
        #expect(findings.orphanCandidates.isEmpty)
        #expect(results.isEmpty)
    }

    @Test("user exclusions suppress orphan and duplicate model candidates")
    func userExclusionsSuppressCandidates() async throws {
        let fixture = try FixtureTree()
        let downloads = try fixture.makeDir("Downloads")
        try fixture.makeDir("Downloads/Skip")
        try fixture.makeFile("Downloads/Skip/model.gguf", byteCount: 512)

        let adapter = makeAdapter(
            knownStores: [],
            orphanRoots: [downloads],
            excludedPaths: ["*/Skip/*"]
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("protected roots are not surfaced as model cleanup candidates")
    func protectedRootsAreSkipped() async throws {
        let fixture = try FixtureTree()
        let downloads = try fixture.makeDir("Downloads")
        let protected = try fixture.makeDir("Downloads/Protected")
        try fixture.makeFile("Downloads/Protected/model.onnx", byteCount: 512)

        let policy = ProtectedRootPolicy(entries: [
            ProtectedRootEntry(path: protected.path, reason: "fixture protected root"),
        ])
        let adapter = makeAdapter(
            knownStores: [],
            orphanRoots: [downloads],
            protectedRoots: policy
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.isEmpty)
    }

    @Test("category gate keeps AI model intelligence out of non-AI profiles")
    func categoryGate() async throws {
        let fixture = try FixtureTree()
        let downloads = try fixture.makeDir("Downloads")
        try fixture.makeFile("Downloads/model.gguf", byteCount: 512)

        let adapter = makeAdapter(
            knownStores: [],
            orphanRoots: [downloads],
            categories: Set(CleanupProfile.light.categories)
        )

        let results = try await adapter.scan(progress: nil)

        #expect(results.isEmpty)
    }

    private func makeAdapter(
        knownStores: [AIModelStoreDefinition],
        orphanRoots: [URL],
        excludedPaths: Set<String> = [],
        protectedRoots: ProtectedRootPolicy = ProtectedRootPolicy(entries: []),
        categories: Set<String>? = [AIModelIntelligenceScanAdapter.category]
    ) -> AIModelIntelligenceScanAdapter {
        AIModelIntelligenceScanAdapter(
            policy: AIModelScanPolicy(
                minimumModelFileSize: 128,
                knownStores: knownStores,
                orphanRoots: orphanRoots,
                excludedPaths: excludedPaths,
                protectedRoots: protectedRoots,
                maxDepth: 6,
                maxEntriesPerRoot: 1_000,
                timeBudgetPerRoot: 5
            ),
            categories: categories
        )
    }

    private final class FixtureTree {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIModelIntelligenceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func makeDir(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func makeFile(_ relative: String, byteCount: Int) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x1, count: byteCount).write(to: url)
            return url
        }
    }
}
