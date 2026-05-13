import Foundation
import Testing
@testable import GargantuaCore

@Suite("DeveloperToolExecutionAdapter")
struct DeveloperToolExecutionAdapterTests {
    struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]

        init(outputs: [String: ProcessOutput]) {
            self.outputs = outputs
        }

        var calls: [StubCall] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
            lock.lock()
            _calls.append(StubCall(executable: executable.path, arguments: arguments, timeout: timeout))
            lock.unlock()

            let key = ([executable.lastPathComponent] + arguments).joined(separator: " ")
            return outputs[key] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    final class AuditSpy: DeveloperToolAuditRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [AuditEntry] = []

        var entries: [AuditEntry] {
            lock.lock()
            defer { lock.unlock() }
            return _entries
        }

        func write(_ entry: AuditEntry) throws {
            lock.lock()
            _entries.append(entry)
            lock.unlock()
        }
    }

    // MARK: - Preview fixtures

    func homebrewPreview(bytes: Int64) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .homebrew,
            commandPreview: ["brew", "cleanup", "-n"],
            items: [
                DeveloperToolPreviewItem(
                    id: "homebrew-0",
                    tool: .homebrew,
                    title: "Would remove foo",
                    reclaimableBytes: bytes,
                    commandPreview: ["brew", "cleanup", "-n"]
                ),
            ],
            rawOutput: ""
        )
    }

    func dockerPreview(
        imageBytes: Int64 = 0,
        volumeBytes: Int64 = 0,
        buildBytes: Int64 = 0
    ) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .docker,
            commandPreview: ["docker", "system", "df"],
            items: [
                DeveloperToolPreviewItem(
                    id: "docker-images",
                    tool: .docker,
                    title: "Images",
                    reclaimableBytes: imageBytes,
                    commandPreview: ["docker", "system", "df"]
                ),
                DeveloperToolPreviewItem(
                    id: "docker-volumes",
                    tool: .docker,
                    title: "Local Volumes",
                    reclaimableBytes: volumeBytes,
                    commandPreview: ["docker", "system", "df"]
                ),
                DeveloperToolPreviewItem(
                    id: "docker-build-cache",
                    tool: .docker,
                    title: "Build Cache",
                    reclaimableBytes: buildBytes,
                    commandPreview: ["docker", "system", "df"]
                ),
            ],
            rawOutput: ""
        )
    }

    func xcodePreview(bytes: Int64?) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .xcode,
            commandPreview: ["xcrun", "simctl", "list", "-j", "devices", "unavailable"],
            items: [
                DeveloperToolPreviewItem(
                    id: "xcode-simulator-AAAA",
                    tool: .xcode,
                    title: "iPhone 14",
                    reclaimableBytes: bytes,
                    commandPreview: ["xcrun", "simctl", "list", "-j", "devices", "unavailable"]
                ),
            ],
            rawOutput: ""
        )
    }

    func pnpmPreview() -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .pnpm,
            commandPreview: ["pnpm", "store", "path"],
            items: [
                DeveloperToolPreviewItem(
                    id: "pnpm-store",
                    tool: .pnpm,
                    title: "pnpm content-addressable store",
                    detail: "/Users/me/Library/pnpm/store/v10",
                    commandPreview: ["pnpm", "store", "path"]
                ),
            ],
            rawOutput: ""
        )
    }

    func goPreview() -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .go,
            commandPreview: ["go", "env", "-json", "GOCACHE", "GOMODCACHE"],
            items: [
                DeveloperToolPreviewItem(
                    id: "go-build-cache",
                    tool: .go,
                    title: "Go build cache",
                    detail: "/Users/me/Library/Caches/go-build",
                    commandPreview: ["go", "env", "-json", "GOCACHE", "GOMODCACHE"]
                ),
            ],
            rawOutput: ""
        )
    }

    func cargoPreview(registrySrc: URL, gitCheckouts: URL) -> DeveloperToolPreview {
        DeveloperToolPreview(
            tool: .cargo,
            commandPreview: ["cargo", "--version"],
            items: [
                DeveloperToolPreviewItem(
                    id: "cargo-registry-src",
                    tool: .cargo,
                    title: "Cargo extracted registry sources",
                    detail: registrySrc.path,
                    reclaimableBytes: DeveloperToolPreviewAdapter.directorySize(at: registrySrc),
                    commandPreview: ["cargo", "--version"]
                ),
                DeveloperToolPreviewItem(
                    id: "cargo-git-checkouts",
                    tool: .cargo,
                    title: "Cargo git dependency checkouts",
                    detail: gitCheckouts.path,
                    reclaimableBytes: DeveloperToolPreviewAdapter.directorySize(at: gitCheckouts),
                    commandPreview: ["cargo", "--version"]
                ),
            ],
            rawOutput: ""
        )
    }

    // MARK: - File helpers

    func makeScratchBinary(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolExecutionAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func makeSizedFile(at url: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: byteCount).write(to: url)
    }
}
