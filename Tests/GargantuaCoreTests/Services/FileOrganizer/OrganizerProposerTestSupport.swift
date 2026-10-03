import Foundation

/// Shared helpers for the CLI-backed organizer proposer tests
/// (`ClaudeCodeOrganizerProposer`, `CodexOrganizerProposer`). Both spawn a
/// real subprocess via an injected `processFactory`, so the cleanest hermetic
/// fake is a tiny executable shell script that emits canned output.
enum OrganizerProposerTestSupport {

    /// Writes an executable `/bin/sh` script with `body` and returns its URL.
    /// The caller is responsible for deleting it.
    static func writeExecutableScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-cli-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Creates a temp source folder containing the named files (1 byte each)
    /// and returns its URL. The caller is responsible for deleting it.
    static func makeSourceFolder(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    /// A throwaway, isolated `UserDefaults` suite so the configuration store
    /// never touches `.standard`.
    static func makeDefaults() -> UserDefaults {
        TestDefaults.suite("org-proposer-test-\(UUID().uuidString)")
    }
}
