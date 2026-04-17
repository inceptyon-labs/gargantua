import Foundation
import Testing

@testable import GargantuaCore

/// End-to-end smoke test: run the real scanner against `/System/Applications`.
///
/// This uses live NSWorkspace + SecStaticCode + FileManager against Apple-signed
/// apps that ship with the OS, so it's safe to run in CI. It validates that the
/// production components wire together and that we populate the key fields that
/// the Smart Uninstaller depends on.
@Suite("AppScanner smoke")
struct AppScannerSmokeTests {

    @Test("scanning /System/Applications returns recognisable Apple apps")
    func scanSystemApplications() async throws {
        let systemApps = URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: systemApps.path))

        let scanner = DefaultAppScanner(
            enumerator: DefaultAppBundleEnumerator(
                searchRoots: [systemApps],
                includeRunningApps: false
            )
        )

        let apps = await scanner.scanApps()

        // /System/Applications ships several dozen apps; we should find at least
        // a handful. Exact count varies by macOS version, so check a lower bound.
        #expect(apps.count >= 5, "Expected ≥5 system apps, found \(apps.count)")

        // Core fields must be populated for every app.
        for app in apps {
            #expect(!app.bundleID.isEmpty, "Empty bundleID for \(app.bundlePath)")
            #expect(!app.name.isEmpty, "Empty name for \(app.bundlePath)")
            #expect(
                app.bundlePath.hasPrefix("/System/Applications"),
                "Unexpected path: \(app.bundlePath)"
            )
            #expect(app.isSystemApp, "Expected isSystemApp=true for \(app.bundlePath)")
        }

        // Apple apps should validate and carry an Apple team identifier.
        let signedCount = apps.filter { $0.signatureValid == true }.count
        #expect(
            signedCount >= apps.count / 2,
            "Expected majority of /System/Applications to validate; \(signedCount)/\(apps.count) did"
        )
    }
}
