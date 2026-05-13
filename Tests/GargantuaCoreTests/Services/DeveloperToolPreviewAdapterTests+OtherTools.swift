import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolPreviewAdapterTests {
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
}
