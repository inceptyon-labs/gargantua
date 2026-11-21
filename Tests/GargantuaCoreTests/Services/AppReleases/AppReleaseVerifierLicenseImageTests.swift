import Foundation
import Testing
@testable import GargantuaCore

private typealias Fixtures = AppReleaseInstallFixtures
private typealias Failure = AppReleaseVerificationFailure

extension RealDiskImageTests {
    @Suite("AppReleaseVerifier license-agreement disk images")
    struct AppReleaseVerifierLicenseImageTests {
        private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

        @discardableResult
        private func runHdiutil(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = Self.hdiutil
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        private func pascal(_ text: String) -> [UInt8] {
            let bytes = Array(text.data(using: .macOSRoman) ?? Data())
            return [UInt8(bytes.count)] + bytes
        }

        private func resource(_ name: String, _ data: [UInt8]) -> [String: Any] {
            ["Attributes": "0x0000", "Data": Data(data), "ID": "5000", "Name": name]
        }

        private func licensePlist() throws -> Data {
            let lpic: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
            let strings = ["English", "Agree", "Disagree", "Print", "Save...", "If you agree, click Agree."]
            let str = [UInt8(0), UInt8(strings.count)] + strings.flatMap(pascal)
            let text = Array("Test license agreement for Gargantua.".data(using: .macOSRoman) ?? Data())
            let plist: [String: Any] = [
                "LPic": [resource("", lpic)],
                "STR#": [resource("English", str)],
                "TEXT": [resource("English SLA", text)],
            ]
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }

        @Test("a disk image with a license agreement fails fast as licenseAgreementRequired",
              .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")))
        func realLicenseDiskImage() throws {
            let directory = try Fixtures.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let folder = directory.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: folder.appendingPathComponent("file.txt"))
            let dmg = directory.appendingPathComponent("Foo.dmg")
            try #require(try runHdiutil(["create", "-quiet", "-srcfolder", folder.path, "-format", "UDZO", dmg.path]) == 0)

            let plist = directory.appendingPathComponent("sla.plist")
            try licensePlist().write(to: plist)
            try #require(try runHdiutil(["udifrez", "-xml", plist.path, "", "-quiet", dmg.path]) == 0)

            let work = directory.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { _ = try? runHdiutil(["detach", "-force", "-quiet", work.path]) }
            #expect(throws: Failure.licenseAgreementRequired) {
                try AppReleaseVerifier(signer: StubCodeSigner(), gatekeeper: AcceptingGatekeeper()).verify(
                    payload: dmg, app: Fixtures.installedApp(at: URL(fileURLWithPath: "/Applications/Foo.app")),
                    candidate: Fixtures.candidate(downloadURL: "https://example.com/Foo.dmg"),
                    strategy: .inPlace, workDirectory: work
                )
            }
        }
    }
}
