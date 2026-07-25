import Foundation
import GargantuaLicensing
import Testing

/// Enforces the invariants `DestructiveSurface.swift` documents rather than
/// trusting review to catch a regression:
///
/// - Production code never mints `DestructiveActionAuthorization.unchecked(_:)`,
///   the test-only bypass of the license gate.
/// - Every `CleanupEngine.clean` call site passes an `authorization:` argument.
/// - Every registered `DestructiveSurface` authorizes cleanly through
///   `LicenseGate.authorize(_:)` when the gate allows.
///
/// Both filesystem scans resolve the repo's `Sources/` directory from
/// `#filePath` so they work from any working directory (Xcode, `swift test`,
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

    @Test("Every CleanupEngine.clean call site passes an authorization")
    func everyCleanCallSitePassesAuthorization() throws {
        let root = Self.requireSourcesRoot()
        let files = Self.swiftFiles(under: root)
        #expect(!files.isEmpty, "Expected to find .swift files under \(root.path)")

        var offenders: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let codeLines = contents.components(separatedBy: .newlines).filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }

            let cleanCount = codeLines.reduce(0) { $0 + $1.components(separatedBy: ".clean(").count - 1 }
            guard cleanCount > 0 else { continue }

            let authorizationCount = codeLines.reduce(0) { $0 + $1.components(separatedBy: "authorization:").count - 1 }
            if authorizationCount < cleanCount {
                offenders.append("\(file.path) (.clean(=\(cleanCount), authorization:=\(authorizationCount)))")
            }
        }

        #expect(
            offenders.isEmpty,
            "Files with fewer `authorization:` labels than `.clean(` call sites: \(offenders.joined(separator: ", "))"
        )
    }

    @Test("Every registered surface authorizes through the license gate")
    func everySurfaceAuthorizesThroughLicenseGate() async {
        // A plain `swift test` (no GARGANTUA_LICENSING) resolves
        // `LicenseGate.currentState()` to `.licensed` unconditionally, so only
        // the allowing branch is reachable from this target. The blocked
        // branch is covered under `Tests/GargantuaLicensingTests/DestructiveSurfaceTests.swift`,
        // which is built with the licensing flag and can reach it.
        let gate = LicenseGate.shared
        for surface in DestructiveSurface.allCases {
            let result = await gate.authorize(surface)
            guard case .success(let token) = result else {
                Issue.record("Expected .success for \(surface), got \(result)")
                continue
            }
            #expect(token.surface == surface)
        }
    }
}
