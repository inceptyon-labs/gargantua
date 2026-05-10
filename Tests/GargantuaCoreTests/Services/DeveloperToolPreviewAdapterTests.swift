import Foundation
import Testing
@testable import GargantuaCore

@Suite("DeveloperToolPreviewAdapter")
struct DeveloperToolPreviewAdapterTests {
    private struct StubCall: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [StubCall] = []
        private let outputs: [String: ProcessOutput]
        private let errors: [String: Error]

        init(outputs: [String: ProcessOutput], errors: [String: Error] = [:]) {
            self.outputs = outputs
            self.errors = errors
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
            if let error = errors[key] {
                throw error
            }
            return outputs[key] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    @Test("env overrides expose installed state and versions")
    func availabilityUsesRuntimeResolvers() throws {
        let brew = try makeScratchBinary(name: "brew")
        let docker = try makeScratchBinary(name: "docker")
        let xcrun = try makeScratchBinary(name: "xcrun")
        let pnpm = try makeScratchBinary(name: "pnpm")
        let go = try makeScratchBinary(name: "go")
        let cargo = try makeScratchBinary(name: "cargo")
        defer {
            try? FileManager.default.removeItem(at: brew.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: docker.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: xcrun.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: go.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: cargo.deletingLastPathComponent())
        }

        let runner = StubRunner(outputs: [
            "brew --version": ProcessOutput(stdout: "Homebrew 4.2.1\n", stderr: "", exitCode: 0),
            "docker --version": ProcessOutput(stdout: "Docker version 25.0.0, build abc\n", stderr: "", exitCode: 0),
            "xcrun xcodebuild -version": ProcessOutput(stdout: "Xcode 16.4\nBuild version 16F6\n", stderr: "", exitCode: 0),
            "pnpm --version": ProcessOutput(stdout: "10.1.0\n", stderr: "", exitCode: 0),
            "go version": ProcessOutput(stdout: "go version go1.24.0 darwin/arm64\n", stderr: "", exitCode: 0),
            "cargo --version": ProcessOutput(stdout: "cargo 1.88.0\n", stderr: "", exitCode: 0),
        ])
        let resolver = DeveloperToolBinaryResolver(environment: [
            DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            DeveloperToolBinaryResolver.xcrunEnvVarName: xcrun.path,
            DeveloperToolBinaryResolver.pnpmEnvVarName: pnpm.path,
            DeveloperToolBinaryResolver.goEnvVarName: go.path,
            DeveloperToolBinaryResolver.cargoEnvVarName: cargo.path,
        ])
        let adapter = DeveloperToolPreviewAdapter(resolver: resolver, runner: runner)

        let availability = adapter.availability()

        #expect(availability.count == DeveloperTool.allCases.count)
        #expect(availability.first { $0.tool == .homebrew }?.isInstalled == true)
        #expect(availability.first { $0.tool == .homebrew }?.version == "Homebrew 4.2.1")
        #expect(availability.first { $0.tool == .docker }?.isInstalled == true)
        #expect(availability.first { $0.tool == .docker }?.version?.hasPrefix("Docker version 25.0.0") == true)
        #expect(availability.first { $0.tool == .xcode }?.version == "Xcode 16.4")
        #expect(availability.first { $0.tool == .pnpm }?.version == "10.1.0")
        #expect(availability.first { $0.tool == .go }?.version?.hasPrefix("go version go1.24.0") == true)
        #expect(availability.first { $0.tool == .cargo }?.version == "cargo 1.88.0")
    }

    @Test("missing binaries report unavailable and preview throws")
    func missingBinary() {
        let resolver = DeveloperToolBinaryResolver(environment: [
            DeveloperToolBinaryResolver.homebrewEnvVarName: "/definitely/not/brew",
        ])
        let adapter = DeveloperToolPreviewAdapter(resolver: resolver, runner: StubRunner(outputs: [:]))

        let availability = adapter.availability(for: .homebrew)

        #expect(!availability.isInstalled)
        #expect(availability.executable == nil)
        #expect(availability.error?.contains("Homebrew") == true)
        #expect(throws: DeveloperToolPreviewError.notInstalled(.homebrew)) {
            _ = try adapter.preview(.homebrew)
        }
    }

    @Test("Homebrew preview invokes cleanup dry-run and parses reclaimable sizes")
    func homebrewPreview() throws {
        let brew = try makeScratchBinary(name: "brew")
        defer { try? FileManager.default.removeItem(at: brew.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "brew cleanup -n": ProcessOutput(
                stdout: """
                Would remove: /Users/me/Library/Caches/Homebrew/foo--1.0 (12.5MB)
                Would remove: /Users/me/Library/Caches/Homebrew/bar--2.0 (1GB)
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.homebrewEnvVarName: brew.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.homebrew)

        #expect(runner.calls.map(\.arguments) == [["cleanup", "-n"]])
        #expect(preview.commandPreview == [brew.path, "cleanup", "-n"])
        #expect(preview.items.count == 2)
        #expect(preview.reclaimableBytes == 1_012_500_000)
    }

    @Test("Docker preview prefers structured system df JSON when available")
    func dockerStructuredPreview() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df --format json": ProcessOutput(
                stdout: """
                {"Type":"Images","TotalCount":"12","Active":"4","Size":"8.5GB","Reclaimable":"2.1GB (24%)"}
                {"Type":"Local Volumes","TotalCount":"5","Active":"5","Size":"10GB","Reclaimable":"0B (0%)"}
                {"Type":"Build Cache","TotalCount":"30","Active":"0","Size":"1.2GB","Reclaimable":"800MB"}
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.docker)

        #expect(runner.calls.map(\.arguments) == [["system", "df", "--format", "json"]])
        #expect(preview.commandPreview == [docker.path, "system", "df", "--format", "json"])
        #expect(preview.items.map(\.title) == ["Images", "Local Volumes", "Build Cache"])
        #expect(preview.items.first?.detail?.contains("Reclaimable: 2.1GB (24%)") == true)
        #expect(preview.reclaimableBytes == 2_900_000_000)
    }

    @Test("Docker preview falls back to legacy table when JSON format is unavailable")
    func dockerPreviewFallsBackToLegacyTable() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df --format json": ProcessOutput(
                stdout: "",
                stderr: "template parsing error: function \"json\" not defined",
                exitCode: 1
            ),
            "docker system df": ProcessOutput(
                stdout: """
                TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
                Images          12        4         8.5GB     2.1GB (24%)
                Build Cache     30        0         1.2GB     800MB
                Volumes         5         5         10GB      0B (0%)
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.docker)

        #expect(runner.calls.map(\.arguments) == [
            ["system", "df", "--format", "json"],
            ["system", "df"],
        ])
        #expect(preview.commandPreview == [docker.path, "system", "df"])
        #expect(preview.items.map(\.title) == ["Images", "Build Cache", "Volumes"])
        #expect(preview.reclaimableBytes == 2_900_000_000)
    }

    @Test("Xcode preview lists unavailable simulator devices")
    func xcodePreview() throws {
        let xcrun = try makeScratchBinary(name: "xcrun")
        defer { try? FileManager.default.removeItem(at: xcrun.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "xcrun simctl list -j devices unavailable": ProcessOutput(
                stdout: """
                {
                  "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
                      {
                        "name": "iPhone 14",
                        "udid": "AAAA-BBBB",
                        "state": "Shutdown",
                        "availabilityError": "runtime profile not found",
                        "dataPathSize": 12000000
                      }
                    ],
                    "com.apple.CoreSimulator.SimRuntime.watchOS-10-0": [
                      {
                        "name": "Apple Watch",
                        "udid": "CCCC-DDDD",
                        "state": "Shutdown",
                        "dataPathSize": 3000000
                      }
                    ]
                  }
                }
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.xcrunEnvVarName: xcrun.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.xcode)

        #expect(runner.calls.map(\.arguments) == [["simctl", "list", "-j", "devices", "unavailable"]])
        #expect(preview.commandPreview == [xcrun.path, "simctl", "list", "-j", "devices", "unavailable"])
        #expect(preview.items.map(\.title) == ["iPhone 14", "Apple Watch"])
        #expect(preview.items.first?.detail?.contains("iOS 17.0") == true)
        #expect(preview.reclaimableBytes == 15_000_000)
    }

    @Test("pnpm preview resolves the global store path")
    func pnpmPreview() throws {
        let pnpm = try makeScratchBinary(name: "pnpm")
        defer { try? FileManager.default.removeItem(at: pnpm.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "pnpm store path": ProcessOutput(stdout: "/Users/me/Library/pnpm/store/v10\n", stderr: "", exitCode: 0),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.pnpmEnvVarName: pnpm.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.pnpm)

        #expect(preview.commandPreview == [pnpm.path, "store", "path"])
        #expect(preview.items.count == 1)
        #expect(preview.items.first?.id == "pnpm-store")
        #expect(preview.items.first?.detail == "/Users/me/Library/pnpm/store/v10")
        #expect(preview.items.first?.reclaimableBytes == 0)
        #expect(preview.reclaimableBytes == 0)
    }

    @Test("pnpm resolver includes nvm-managed node bins")
    func pnpmResolverIncludesNVMManagedBins() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolPreviewAdapterTests-home-\(UUID().uuidString)", isDirectory: true)
        let pnpm = home
            .appendingPathComponent(".nvm/versions/node/v22.18.0/bin", isDirectory: true)
            .appendingPathComponent("pnpm")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeScratchBinary(at: pnpm)

        let paths = DeveloperToolBinaryResolver
            .nodeManagedPnpmCandidatePaths(homeDirectory: home)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }

        #expect(paths == [pnpm.resolvingSymlinksInPath().path])
    }

    @Test("Go preview reads shared cache locations")
    func goPreview() throws {
        let go = try makeScratchBinary(name: "go")
        let caches = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolPreviewAdapterTests-go-caches-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: go.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: caches)
        }
        let buildCache = caches.appendingPathComponent("go-build", isDirectory: true)
        let moduleCache = caches.appendingPathComponent("pkg/mod", isDirectory: true)
        try makeSizedFile(at: buildCache.appendingPathComponent("a"), byteCount: 128)
        try makeSizedFile(at: moduleCache.appendingPathComponent("b"), byteCount: 256)

        let runner = StubRunner(outputs: [
            "go env -json GOCACHE GOMODCACHE": ProcessOutput(
                stdout: """
                {
                  "GOCACHE": "\(buildCache.path)",
                  "GOMODCACHE": "\(moduleCache.path)"
                }
                """,
                stderr: "",
                exitCode: 0
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.goEnvVarName: go.path,
            ]),
            runner: runner
        )

        let preview = try adapter.preview(.go)

        #expect(preview.commandPreview == [go.path, "env", "-json", "GOCACHE", "GOMODCACHE"])
        #expect(preview.items.map(\.id) == ["go-build-cache", "go-module-cache"])
        #expect(preview.items.map(\.detail) == [buildCache.path, moduleCache.path])
        #expect(preview.items.compactMap(\.reclaimableBytes).allSatisfy { $0 > 0 })
        #expect(preview.reclaimableBytes > 0)
    }

    @Test("Cargo preview sizes rehydratable Cargo home caches")
    func cargoPreview() throws {
        let cargo = try makeScratchBinary(name: "cargo")
        let cargoHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolPreviewAdapterTests-cargo-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cargo.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: cargoHome)
        }
        let registrySrc = cargoHome.appendingPathComponent("registry/src", isDirectory: true)
        let gitCheckouts = cargoHome.appendingPathComponent("git/checkouts", isDirectory: true)
        try makeSizedFile(at: registrySrc.appendingPathComponent("crate/lib.rs"), byteCount: 128)
        try makeSizedFile(at: gitCheckouts.appendingPathComponent("repo/main.rs"), byteCount: 256)

        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.cargoEnvVarName: cargo.path,
            ]),
            runner: StubRunner(outputs: [:]),
            cargoHome: cargoHome
        )

        let preview = try adapter.preview(.cargo)

        #expect(preview.commandPreview == [cargo.path, "--version"])
        #expect(preview.items.map(\.id) == ["cargo-registry-src", "cargo-git-checkouts"])
        #expect(preview.items.map(\.detail) == [registrySrc.path, gitCheckouts.path])
        #expect(preview.reclaimableBytes > 0)
    }

    @Test("preview command failures are surfaced without fallback cleanup execution")
    func commandFailure() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df": ProcessOutput(stdout: "", stderr: "daemon unavailable", exitCode: 1),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        #expect(throws: DeveloperToolPreviewError.commandFailed(
            tool: .docker,
            exitCode: 1,
            stderr: "daemon unavailable"
        )) {
            _ = try adapter.preview(.docker)
        }
        #expect(runner.calls.map(\.arguments) == [
            ["system", "df", "--format", "json"],
            ["system", "df"],
        ])
    }

    @Test("Docker daemon-down stderr maps to .daemonNotRunning, not commandFailed")
    func dockerDaemonNotRunningSurfacesAsDaemonNotRunning() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(outputs: [
            "docker system df": ProcessOutput(
                stdout: "",
                stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
                exitCode: 1
            ),
        ])
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        #expect(throws: DeveloperToolPreviewError.daemonNotRunning(.docker)) {
            _ = try adapter.preview(.docker)
        }
    }

    @Test("Docker preview timeout maps to daemon-stopped recovery")
    func dockerPreviewTimeoutMapsToDaemonStopped() throws {
        let docker = try makeScratchBinary(name: "docker")
        defer { try? FileManager.default.removeItem(at: docker.deletingLastPathComponent()) }

        let runner = StubRunner(
            outputs: [:],
            errors: [
                "docker system df --format json": ProcessRunnerError.timedOut(seconds: 15),
            ]
        )
        let adapter = DeveloperToolPreviewAdapter(
            resolver: DeveloperToolBinaryResolver(environment: [
                DeveloperToolBinaryResolver.dockerEnvVarName: docker.path,
            ]),
            runner: runner
        )

        #expect(throws: DeveloperToolPreviewError.daemonNotRunning(.docker)) {
            _ = try adapter.preview(.docker)
        }
        #expect(runner.calls.map(\.arguments) == [
            ["system", "df", "--format", "json"],
        ])
    }

    @Test("isDockerDaemonNotRunning matches both canonical phrases")
    func dockerDaemonStderrPatterns() {
        #expect(DeveloperToolPreviewError.isDockerDaemonNotRunning(
            stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"
        ))
        #expect(DeveloperToolPreviewError.isDockerDaemonNotRunning(
            stderr: "error during connect: ... Is the docker daemon running?"
        ))
        #expect(!DeveloperToolPreviewError.isDockerDaemonNotRunning(
            stderr: "permission denied while trying to connect"
        ))
        #expect(!DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: ""))
    }

    @Test("adapter exposes no destructive prune commands")
    func noDestructiveCommands() {
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .homebrew) == ["cleanup", "-n"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .docker) == ["system", "df"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .xcode) == ["simctl", "list", "-j", "devices", "unavailable"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .pnpm) == ["store", "path"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .go) == ["env", "-json", "GOCACHE", "GOMODCACHE"])
        #expect(DeveloperToolPreviewAdapter.previewArguments(for: .cargo) == ["--version"])
        #expect(DeveloperToolPreviewAdapter.structuredPreviewArguments(for: .docker) == ["system", "df", "--format", "json"])
    }

    private func makeScratchBinary(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolPreviewAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try makeScratchBinary(at: url)
        return url
    }

    private func makeScratchBinary(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeSizedFile(at url: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: byteCount).write(to: url)
    }
}
