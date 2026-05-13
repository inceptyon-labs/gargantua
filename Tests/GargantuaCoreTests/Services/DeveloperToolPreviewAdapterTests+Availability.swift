import Foundation
import Testing
@testable import GargantuaCore

extension DeveloperToolPreviewAdapterTests {
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
}
