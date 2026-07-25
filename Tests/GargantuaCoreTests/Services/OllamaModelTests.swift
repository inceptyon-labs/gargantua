import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

@Suite("OllamaModelInventory")
struct OllamaModelInventoryTests {

    @Test("shared blobs count toward total but only unique blobs are reclaimable")
    func sharedBlobAccounting() throws {
        let store = try OllamaFixture()
        // base blob is shared by both models; each has a unique config + weights.
        try store.blob("sha256-base", bytes: 500)
        try store.blob("sha256-cfgA", bytes: 10)
        try store.blob("sha256-modelA", bytes: 1000)
        try store.blob("sha256-cfgB", bytes: 20)
        try store.blob("sha256-modelB", bytes: 2000)
        try store.manifest("registry.ollama.ai/library/llama3/8b", config: "sha256:cfgA", layers: ["sha256:modelA", "sha256:base"])
        try store.manifest("registry.ollama.ai/library/llama3/70b", config: "sha256:cfgB", layers: ["sha256:modelB", "sha256:base"])

        let models = OllamaModelInventory(root: store.root).load()
        let byRef = Dictionary(uniqueKeysWithValues: models.map { ($0.reference, $0) })

        let small = try #require(byRef["llama3:8b"])
        #expect(small.totalBytes == 1510)
        #expect(small.reclaimableBytes == 1010)
        #expect(small.sharedBytes == 500)
        #expect(small.sharedWith == ["llama3:70b"])

        let big = try #require(byRef["llama3:70b"])
        #expect(big.totalBytes == 2520)
        #expect(big.reclaimableBytes == 2020)
        #expect(big.sharedWith == ["llama3:8b"])
    }

    @Test("a model whose blobs are all unique is fully reclaimable")
    func fullyReclaimableModel() throws {
        let store = try OllamaFixture()
        try store.blob("sha256-solo", bytes: 4096)
        try store.manifest("registry.ollama.ai/library/mistral/7b", config: nil, layers: ["sha256:solo"])

        let models = OllamaModelInventory(root: store.root).load()
        #expect(models.count == 1)
        #expect(models[0].reference == "mistral:7b")
        #expect(models[0].reclaimableBytes == 4096)
        #expect(models[0].totalBytes == 4096)
        #expect(models[0].sharedWith.isEmpty)
    }

    @Test("namespaced and custom-registry references are preserved")
    func referenceDerivation() throws {
        let store = try OllamaFixture()
        try store.blob("sha256-a", bytes: 100)
        try store.blob("sha256-b", bytes: 100)
        try store.manifest("registry.ollama.ai/jnew00/custom/latest", config: nil, layers: ["sha256:a"])
        try store.manifest("myregistry.com/team/model/v2", config: nil, layers: ["sha256:b"])

        let refs = Set(OllamaModelInventory(root: store.root).load().map(\.reference))
        #expect(refs.contains("jnew00/custom:latest"))
        #expect(refs.contains("myregistry.com/team/model:v2"))
    }

    @Test("missing models directory yields no models")
    func missingStore() throws {
        let store = try OllamaFixture(createDirs: false)
        #expect(OllamaModelInventory(root: store.root).load().isEmpty)
    }

    @Test("OLLAMA_MODELS overrides the default root")
    func resolveRootHonorsEnv() {
        let custom = OllamaModelInventory.resolveRoot(
            environment: ["OLLAMA_MODELS": "/tmp/custom-ollama"],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        #expect(custom.path == "/tmp/custom-ollama")

        let fallback = OllamaModelInventory.resolveRoot(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        #expect(fallback.path == "/Users/test/.ollama/models")
    }
}

@Suite("OllamaModelScanAdapter")
struct OllamaModelScanAdapterTests {

    @Test("emits one review result per model sized to reclaimable bytes")
    func emitsPerModelResults() async throws {
        let store = try OllamaFixture()
        try store.blob("sha256-base", bytes: 500)
        try store.blob("sha256-modelA", bytes: 1000)
        try store.manifest("registry.ollama.ai/library/llama3/8b", config: nil, layers: ["sha256:modelA", "sha256:base"])
        try store.manifest("registry.ollama.ai/library/qwen/0.5b", config: nil, layers: ["sha256:base"])

        let adapter = OllamaModelScanAdapter(
            inventory: OllamaModelInventory(root: store.root),
            categories: [OllamaModelScanAdapter.category]
        )
        let results = try await adapter.scan(progress: nil)

        let llama = try #require(results.first { $0.ollamaModelReference == "llama3:8b" })
        #expect(llama.name == "Ollama model — llama3:8b")
        #expect(llama.safety == .review)
        #expect(llama.size == 1000) // base is shared with qwen, so not reclaimable here
        #expect(llama.isOllamaModel)
        #expect(llama.regenerateCommand == "ollama pull llama3:8b")
        #expect(llama.explanation.contains("shared"))
    }

    @Test("category gate keeps Ollama models out of non-AI profiles")
    func categoryGate() async throws {
        let store = try OllamaFixture()
        try store.blob("sha256-solo", bytes: 256)
        try store.manifest("registry.ollama.ai/library/gemma/2b", config: nil, layers: ["sha256:solo"])

        let adapter = OllamaModelScanAdapter(
            inventory: OllamaModelInventory(root: store.root),
            categories: Set(CleanupProfile.light.categories)
        )
        #expect(try await adapter.scan(progress: nil).isEmpty)
    }
}

@Suite("OllamaModelCleanupRouter")
struct OllamaModelCleanupRouterTests {

    @Test("routes the model reference to the deleter and reports success")
    func successfulDelete() async {
        let deleter = RecordingDeleter()
        let router = OllamaModelCleanupRouter(deleter: deleter)
        let item = OllamaModelScanAdapter.makeResult(.sample(reference: "llama3:8b"))

        let result = await router.run(item: item)
        #expect(result.succeeded)
        #expect(await deleter.references == ["llama3:8b"])
    }

    @Test("daemon-unreachable surfaces as a per-item error")
    func unreachableSurfacesError() async {
        let router = OllamaModelCleanupRouter(deleter: ThrowingDeleter(error: .unreachable(detail: "connection refused")))
        let item = OllamaModelScanAdapter.makeResult(.sample(reference: "llama3:8b"))

        let result = await router.run(item: item)
        #expect(!result.succeeded)
        #expect(result.error?.contains("not reachable") == true)
    }

    @Test("non-Ollama item fails closed")
    func untaggedItemFails() async {
        let router = OllamaModelCleanupRouter(deleter: RecordingDeleter())
        let item = ScanResult(
            id: "native:something",
            name: "Not an Ollama model",
            path: "/tmp/x",
            size: 1,
            safety: .review,
            confidence: 50,
            explanation: "",
            source: SourceAttribution(name: "x"),
            category: "ai_models"
        )
        let result = await router.run(item: item)
        #expect(!result.succeeded)
    }
}

@Suite("CleanupEngine + Ollama")
struct CleanupEngineOllamaTests {

    @Test("Ollama models route to the deleter, not the trash mover")
    @MainActor
    func routesToDeleter() async {
        let deleter = RecordingDeleter()
        let engine = CleanupEngine(
            homeDirectoryForTesting: FileManager.default.homeDirectoryForCurrentUser,
            ollamaModelRunner: OllamaModelCleanupRouter(deleter: deleter)
        )
        let item = OllamaModelScanAdapter.makeResult(.sample(reference: "deepseek:14b"))

        let result = await engine.clean([item], method: .trash, authorization: .unchecked(.aiModels))
        #expect(result.allSucceeded)
        #expect(await deleter.references == ["deepseek:14b"])
    }
}

// MARK: - Fixtures

private extension OllamaModelInventoryItem {
    static func sample(reference: String) -> OllamaModelInventoryItem {
        OllamaModelInventoryItem(
            reference: reference,
            manifestPath: "/tmp/manifests/\(reference)",
            blobDigests: ["sha256:weights"],
            totalBytes: 1000,
            reclaimableBytes: 1000,
            sharedWith: [],
            lastModified: nil
        )
    }
}

private actor RecordingDeleter: OllamaModelDeleting {
    private(set) var references: [String] = []
    func delete(reference: String) async throws {
        references.append(reference)
    }
}

private struct ThrowingDeleter: OllamaModelDeleting {
    let error: OllamaModelDeleteError
    func delete(reference: String) async throws { throw error }
}

private final class OllamaFixture {
    let root: URL

    init(createDirs: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OllamaModelTests-\(UUID().uuidString)", isDirectory: true)
        if createDirs {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("blobs"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("manifests"),
                withIntermediateDirectories: true
            )
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func blob(_ name: String, bytes: Int) throws {
        let url = root.appendingPathComponent("blobs/\(name)")
        try Data(repeating: 0x2, count: bytes).write(to: url)
    }

    func manifest(_ relativePath: String, config: String?, layers: [String]) throws {
        let url = root.appendingPathComponent("manifests/\(relativePath)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var json: [String: Any] = ["layers": layers.map { ["digest": $0] }]
        if let config { json["config"] = ["digest": config] }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
    }
}
