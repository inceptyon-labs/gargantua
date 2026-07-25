import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolExecutionAdapterTests {
    @Test("Cargo extracted cache purge removes only previewed cache directories")
    func cargoCachePurge() throws {
        let cargo = try makeScratchBinary(name: "cargo")
        let cargoHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolExecutionAdapterTests-cargo-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cargo.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: cargoHome)
        }
        let registrySrc = cargoHome.appendingPathComponent("registry/src", isDirectory: true)
        let gitCheckouts = cargoHome.appendingPathComponent("git/checkouts", isDirectory: true)
        let registryCache = cargoHome.appendingPathComponent("registry/cache", isDirectory: true)
        // Candidate target that is previewed but never materializes on disk —
        // it must show up in the intent entry's files (what we meant to purge)
        // but be absent from the outcome entry's files (what we actually
        // removed), so this test cannot pass an implementation that conflates
        // the two lists.
        let missingRegistrySrc = cargoHome.appendingPathComponent("missing-crate/registry/src", isDirectory: true)
        try makeSizedFile(at: registrySrc.appendingPathComponent("crate/lib.rs"), byteCount: 128)
        try makeSizedFile(at: gitCheckouts.appendingPathComponent("repo/main.rs"), byteCount: 256)
        try makeSizedFile(at: registryCache.appendingPathComponent("crate.crate"), byteCount: 512)

        let audit = AuditSpy()
        let adapter = DeveloperToolExecutionAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.cargoEnvVarName: cargo.path,
            ]),
            runner: StubRunner(outputs: [:]),
            auditRecorder: audit
        )

        var preview = cargoPreview(registrySrc: registrySrc, gitCheckouts: gitCheckouts)
        preview = DeveloperToolPreview(
            tool: preview.tool,
            commandPreview: preview.commandPreview,
            items: preview.items + [
                DeveloperToolPreviewItem(
                    id: "cargo-registry-src",
                    tool: .cargo,
                    title: "Cargo extracted registry sources (missing)",
                    detail: missingRegistrySrc.path,
                    reclaimableBytes: 64,
                    commandPreview: ["cargo", "--version"]
                ),
            ],
            rawOutput: preview.rawOutput
        )

        let result = try adapter.execute(
            .cargoPurgeExtractedCaches,
            preview: preview,
            confirmationMethod: .summaryDialog
        )

        #expect(audit.entries.count == 2)
        #expect(audit.entries.first?.status == .attempted)
        #expect(audit.entries.first?.id == audit.entries.last?.id)
        let intentEntry = try #require(audit.entries.first)
        #expect(
            intentEntry.files.map(\.path).sorted() ==
                [gitCheckouts.path, missingRegistrySrc.path, registrySrc.path].sorted()
        )

        let entry = try #require(audit.entries.last)
        #expect(!FileManager.default.fileExists(atPath: registrySrc.path))
        #expect(!FileManager.default.fileExists(atPath: gitCheckouts.path))
        #expect(FileManager.default.fileExists(atPath: registryCache.path))
        #expect(result.commandPreview == [cargo.path, "cache", "purge-extracted"])
        #expect(result.estimatedBytesFreed > 0)
        #expect(entry.command == "cargo cache purge-extracted")
        #expect(entry.status == .completed)
        #expect(entry.files.map(\.path).sorted() == [gitCheckouts.path, registrySrc.path].sorted())
        #expect(!entry.files.map(\.path).contains(missingRegistrySrc.path))
        #expect(entry.safetyLevel == .review)
    }
}
