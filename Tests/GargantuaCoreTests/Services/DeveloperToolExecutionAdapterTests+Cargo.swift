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

        let result = try adapter.execute(
            .cargoPurgeExtractedCaches,
            preview: cargoPreview(registrySrc: registrySrc, gitCheckouts: gitCheckouts),
            confirmationMethod: .summaryDialog
        )

        let entry = try #require(audit.entries.first)
        #expect(!FileManager.default.fileExists(atPath: registrySrc.path))
        #expect(!FileManager.default.fileExists(atPath: gitCheckouts.path))
        #expect(FileManager.default.fileExists(atPath: registryCache.path))
        #expect(result.commandPreview == [cargo.path, "cache", "purge-extracted"])
        #expect(result.estimatedBytesFreed > 0)
        #expect(entry.command == "cargo cache purge-extracted")
        #expect(entry.files.map(\.path).sorted() == [gitCheckouts.path, registrySrc.path].sorted())
        #expect(entry.safetyLevel == .review)
    }
}
