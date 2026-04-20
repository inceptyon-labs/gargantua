import Foundation
import Testing
@testable import GargantuaCore

@Suite("VendoredBinarySelfCheck")
struct VendoredBinarySelfCheckTests {
    private static func makeScratchBinary(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VendoredBinarySelfCheckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("prints resolved paths for both vendored helpers")
    func resolveLines() throws {
        let fclones = try Self.makeScratchBinary(named: "fclones")
        let czkawka = try Self.makeScratchBinary(named: "czkawka_cli")
        defer {
            try? FileManager.default.removeItem(at: fclones.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: czkawka.deletingLastPathComponent())
        }

        let lines = try VendoredBinarySelfCheck.resolveLines(
            fclonesResolver: FclonesBinaryResolver(environment: [:], bundledURL: fclones),
            czkawkaResolver: CzkawkaBinaryResolver(environment: [:], bundledURL: czkawka)
        )

        #expect(lines == [
            "fclones: \(fclones.path)",
            "czkawka_cli: \(czkawka.path)",
        ])
    }
}
