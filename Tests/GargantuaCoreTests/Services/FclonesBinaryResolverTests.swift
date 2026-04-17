import Foundation
import Testing
@testable import GargantuaCore

@Suite("FclonesBinaryResolver")
struct FclonesBinaryResolverTests {

    private static func makeScratchBinary(executable: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FclonesResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fclones")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return url
    }

    @Test("env var override resolves to the provided executable")
    func envVarOverride() throws {
        let binary = try Self.makeScratchBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }

        let resolver = FclonesBinaryResolver(
            environment: [FclonesBinaryResolver.envVarName: binary.path],
            bundledURL: nil
        )

        #expect(try resolver.resolve().path == binary.path)
        #expect(resolver.isAvailable())
    }

    @Test("env var pointing at missing file raises notFound")
    func envVarMissing() {
        let resolver = FclonesBinaryResolver(
            environment: [FclonesBinaryResolver.envVarName: "/definitely/not/a/real/path/fclones"],
            bundledURL: nil
        )

        #expect(throws: FclonesBinaryResolver.ResolutionError.notFound) {
            _ = try resolver.resolve()
        }
    }

    @Test("env var pointing at non-executable raises notExecutable")
    func envVarNotExecutable() throws {
        let binary = try Self.makeScratchBinary(executable: false)
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }

        let resolver = FclonesBinaryResolver(
            environment: [FclonesBinaryResolver.envVarName: binary.path],
            bundledURL: nil
        )

        #expect(throws: FclonesBinaryResolver.ResolutionError.notExecutable(path: binary.path)) {
            _ = try resolver.resolve()
        }
    }

    @Test("falls back to bundled URL when PATH lookups miss")
    func bundledFallback() throws {
        let binary = try Self.makeScratchBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }

        let resolver = FclonesBinaryResolver(
            environment: [:],
            bundledURL: binary
        )

        // NOTE: If a real fclones is installed at one of the candidate paths,
        // resolve() will short-circuit to it before reaching the bundle. That's
        // still correct behavior; accept whichever executable we get back.
        let resolved = try resolver.resolve()
        #expect(FileManager.default.isExecutableFile(atPath: resolved.path))
    }

    @Test("empty env and no bundled URL yields notFound when no system binary present")
    func nothingAvailable() {
        // Skip if the host actually has fclones installed.
        let haveSystemBinary = FclonesBinaryResolver.candidatePaths.contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard !haveSystemBinary else { return }

        let resolver = FclonesBinaryResolver(environment: [:], bundledURL: nil)
        #expect(!resolver.isAvailable())
    }
}
