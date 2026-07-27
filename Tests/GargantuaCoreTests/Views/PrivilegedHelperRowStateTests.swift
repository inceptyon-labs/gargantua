import Foundation
import Testing
@testable import GargantuaCore

@Suite("Privileged helper row state")
struct PrivilegedHelperRowStateTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivilegedHelperRowStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - isHelperBundled

    @Test("Bundle with the launch daemon plist at the right path is bundled")
    func bundledWhenPlistPresent() {
        let bundleURL = makeTempDir()
        defer { removeTempDir(bundleURL) }

        let launchDaemonsDir = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchDaemonsDir, withIntermediateDirectories: true)
        let plistURL = launchDaemonsDir.appendingPathComponent(PrivilegedHelperConfiguration.helperPlistName)
        FileManager.default.createFile(atPath: plistURL.path, contents: Data())

        #expect(PrivilegedHelperConfiguration.isHelperBundled(bundleURL: bundleURL) == true)
    }

    @Test("Bundle with no LaunchDaemons directory at all is not bundled")
    func notBundledWhenDirectoryMissing() {
        let bundleURL = makeTempDir()
        defer { removeTempDir(bundleURL) }

        #expect(PrivilegedHelperConfiguration.isHelperBundled(bundleURL: bundleURL) == false)
    }

    @Test("Bundle with LaunchDaemons directory but a differently-named plist is not bundled")
    func notBundledWhenPlistNameMismatched() {
        let bundleURL = makeTempDir()
        defer { removeTempDir(bundleURL) }

        let launchDaemonsDir = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchDaemonsDir, withIntermediateDirectories: true)
        let wrongPlistURL = launchDaemonsDir.appendingPathComponent("com.example.other-helper.plist")
        FileManager.default.createFile(atPath: wrongPlistURL.path, contents: Data())

        #expect(PrivilegedHelperConfiguration.isHelperBundled(bundleURL: bundleURL) == false)
    }

    // MARK: - status/bundled -> row state mapping

    @Test("Enabled maps to granted")
    func enabledMapsToGranted() {
        #expect(PrivilegedHelperRowState(status: .enabled, isHelperBundled: true) == .granted)
        #expect(PrivilegedHelperRowState(status: .enabled, isHelperBundled: false) == .granted)
    }

    @Test("Requires approval maps to needs approval")
    func requiresApprovalMapsToNeedsApproval() {
        #expect(PrivilegedHelperRowState(status: .requiresApproval, isHelperBundled: true) == .needsApproval)
    }

    @Test("Not registered maps to needs approval")
    func notRegisteredMapsToNeedsApproval() {
        #expect(PrivilegedHelperRowState(status: .notRegistered, isHelperBundled: true) == .needsApproval)
    }

    @Test("Not found and bundled maps to registration refused")
    func notFoundBundledMapsToRegistrationRefused() {
        #expect(PrivilegedHelperRowState(status: .notFound, isHelperBundled: true) == .registrationRefused)
    }

    @Test("Not found and not bundled maps to not bundled")
    func notFoundNotBundledMapsToNotBundled() {
        #expect(PrivilegedHelperRowState(status: .notFound, isHelperBundled: false) == .notBundled)
    }

    @Test("Unknown status maps to status unknown with the raw value")
    func unknownMapsToStatusUnknown() {
        #expect(PrivilegedHelperRowState(status: .unknown(42), isHelperBundled: true) == .statusUnknown(42))
        #expect(PrivilegedHelperRowState(status: .unknown(42), isHelperBundled: false) == .statusUnknown(42))
    }

    // MARK: - offersRegistrationRetry

    @Test("Granted does not offer a registration retry")
    func grantedDoesNotOfferRetry() {
        #expect(PrivilegedHelperRowState.granted.offersRegistrationRetry == false)
    }

    @Test("Needs approval offers a registration retry")
    func needsApprovalOffersRetry() {
        #expect(PrivilegedHelperRowState.needsApproval.offersRegistrationRetry == true)
    }

    @Test("Registration refused offers a registration retry")
    func registrationRefusedOffersRetry() {
        #expect(PrivilegedHelperRowState.registrationRefused.offersRegistrationRetry == true)
    }

    @Test("Not bundled does not offer a registration retry")
    func notBundledDoesNotOfferRetry() {
        #expect(PrivilegedHelperRowState.notBundled.offersRegistrationRetry == false)
    }

    @Test("Status unknown offers a registration retry")
    func statusUnknownOffersRetry() {
        #expect(PrivilegedHelperRowState.statusUnknown(7).offersRegistrationRetry == true)
    }
}
