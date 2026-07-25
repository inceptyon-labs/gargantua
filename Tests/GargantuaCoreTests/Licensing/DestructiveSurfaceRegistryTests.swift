import Foundation
import GargantuaLicensing
import Testing

/// Enforces the one invariant `DestructiveSurface.swift` documents that the
/// compiler cannot: production code never mints
/// `DestructiveActionAuthorization.unchecked(_:)`, the test-only bypass of the
/// license gate.
///
/// Everything else the registry promises is already a compile error — the
/// destructive entry points take `authorization:` with no default — so there is
/// nothing left for a source scan to add.
///
/// The filesystem scan resolves the repo's `Sources/` directory from
/// `#filePath` so it works from any working directory (Xcode, `swift test`,
/// CI) rather than a hardcoded absolute path.
@Suite("DestructiveSurfaceRegistry")
struct DestructiveSurfaceRegistryTests {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Licensing
            .deletingLastPathComponent() // GargantuaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources")
    }

    /// Fails loudly (rather than vacuously passing on an empty scan) when the
    /// path arithmetic above stops landing on the real `Sources/` directory.
    private static func requireSourcesRoot() -> URL {
        let root = sourcesRoot
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue, "Expected a Sources directory at \(root.path)")
        return root
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(root.path)")
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    @Test("The test-only authorization mint never appears in production code")
    func uncheckedMintNeverAppearsInSources() throws {
        let root = Self.requireSourcesRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "Expected to find .swift files under \(root.path)")

        var offenders: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated()
                where line.contains(".unchecked(") {
                offenders.append("\(file.path):\(index + 1)")
            }
        }

        #expect(
            offenders.isEmpty,
            "Production code must never mint DestructiveActionAuthorization.unchecked(_:): \(offenders.joined(separator: ", "))"
        )
    }
}
