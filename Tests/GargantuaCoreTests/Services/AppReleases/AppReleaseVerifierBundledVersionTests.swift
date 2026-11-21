import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseVerifier bundled version")
struct AppReleaseVerifierBundledVersionTests {
    private typealias Fixtures = AppReleaseInstallFixtures

    private let verifier = AppReleaseVerifier(signer: StubCodeSigner(), gatekeeper: AcceptingGatekeeper())

    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A fresh directory with `src/Foo.app` 2.5 (250) and an empty `work`.
    private func makeSource() throws -> URL {
        let directory = try Fixtures.makeTemporaryDirectory()
        let app = directory.appendingPathComponent("src/Foo.app", isDirectory: true)
        try Fixtures.writeBundle(at: app, short: "2.5", build: "250")
        let work = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return directory
    }

    @Test("reads the app's version from a zip, and finds no app under another bundle ID")
    func zipPayload() throws {
        let directory = try makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("src", isDirectory: true)
        let work = directory.appendingPathComponent("work", isDirectory: true)
        let zip = directory.appendingPathComponent("Foo.zip")
        let app = source.appendingPathComponent("Foo.app").path
        try #require(try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app, zip.path]) == 0)

        #expect(try verifier.bundledVersion(of: Fixtures.bundleID, in: zip, workDirectory: work)
            == AppReleaseVersion(short: "2.5", build: "250"))

        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: AppReleaseVerificationFailure.appNotFound) {
            try verifier.bundledVersion(of: "com.example.Other", in: zip, workDirectory: other)
        }
    }

    @Test("reads the app's version where a disk image mounts, copies nothing, and detaches",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
    func diskImagePayload() throws {
        let directory = try makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("src", isDirectory: true)
        let work = directory.appendingPathComponent("work", isDirectory: true)
        let dmg = directory.appendingPathComponent("Foo.dmg")
        try #require(try run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path, "-format", "UDZO", dmg.path]) == 0)
        let mounts = work.appendingPathComponent("mounts", isDirectory: true)
        defer {
            for volume in AppReleaseVerifier.mountedVolumes(under: mounts) {
                _ = try? run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", volume])
            }
        }

        #expect(try verifier.bundledVersion(of: Fixtures.bundleID, in: dmg, workDirectory: work)
            == AppReleaseVersion(short: "2.5", build: "250"))
        #expect(AppReleaseVerifier.mountedVolumes(under: mounts).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("extracted").path))
    }
}
