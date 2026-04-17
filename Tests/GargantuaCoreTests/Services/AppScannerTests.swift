import Foundation
import Testing

@testable import GargantuaCore

@Suite("AppScanner")
struct AppScannerTests {

    // MARK: - Stubs

    private struct StubEnumerator: AppBundleEnumerating {
        let urls: [URL]
        func enumerateBundles() -> [URL] { urls }
    }

    private struct StubReader: AppBundleReading {
        let metadata: [String: AppBundleMetadata]
        let sizes: [String: Int64]

        func readMetadata(bundleURL: URL) -> AppBundleMetadata? {
            metadata[bundleURL.path]
        }

        func sizeOnDisk(bundleURL: URL) -> Int64? {
            sizes[bundleURL.path]
        }
    }

    private struct StubRunningChecker: RunningAppChecking {
        let running: Set<String>
        func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    }

    private struct StubVerifier: CodeSignatureVerifying {
        let infos: [String: CodeSignatureInfo]
        let defaultInfo: CodeSignatureInfo

        init(infos: [String: CodeSignatureInfo], defaultInfo: CodeSignatureInfo = .unknown) {
            self.infos = infos
            self.defaultInfo = defaultInfo
        }

        func verify(bundleURL: URL) -> CodeSignatureInfo {
            infos[bundleURL.path] ?? defaultInfo
        }
    }

    private static func meta(
        bundleID: String,
        name: String,
        path: String,
        displayName: String? = nil,
        shortVersion: String? = "1.0",
        bundleVersion: String? = "100"
    ) -> AppBundleMetadata {
        AppBundleMetadata(
            bundleID: bundleID,
            name: name,
            displayName: displayName,
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            bundlePath: path,
            executablePath: "\(path)/Contents/MacOS/\(name)",
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedDate: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    // MARK: - Happy path

    @Test("scanApps produces AppInfo per readable bundle with signature + running state")
    func happyPath() async throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let xcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")

        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [chromeURL, xcodeURL]),
            reader: StubReader(
                metadata: [
                    chromeURL.path: Self.meta(
                        bundleID: "com.google.Chrome",
                        name: "Google Chrome",
                        path: chromeURL.path
                    ),
                    xcodeURL.path: Self.meta(
                        bundleID: "com.apple.dt.Xcode",
                        name: "Xcode",
                        path: xcodeURL.path
                    ),
                ],
                sizes: [
                    chromeURL.path: 500_000_000,
                    xcodeURL.path: 15_000_000_000,
                ]
            ),
            runningChecker: StubRunningChecker(running: ["com.google.Chrome"]),
            signatureVerifier: StubVerifier(
                infos: [
                    chromeURL.path: CodeSignatureInfo(valid: true, teamIdentifier: "EQHXZ8M8AV"),
                    xcodeURL.path: CodeSignatureInfo(
                        valid: true,
                        teamIdentifier: "Apple Software"
                    ),
                ]
            )
        )

        let apps = await scanner.scanApps()
        #expect(apps.count == 2)

        let chrome = try #require(apps.first(where: { $0.bundleID == "com.google.Chrome" }))
        #expect(chrome.name == "Google Chrome")
        #expect(chrome.isRunning == true)
        #expect(chrome.isSystemApp == false)
        #expect(chrome.teamIdentifier == "EQHXZ8M8AV")
        #expect(chrome.signatureValid == true)
        #expect(chrome.sizeOnDisk == 500_000_000)
        #expect(chrome.bundlePath == chromeURL.path)

        let xcode = try #require(apps.first(where: { $0.bundleID == "com.apple.dt.Xcode" }))
        #expect(xcode.isRunning == false)
        // Xcode lives in /Applications, not /System/, so it is not a system app even
        // though it is Apple-signed. This matches user expectations — Xcode is
        // user-installable and user-removable.
        #expect(xcode.isSystemApp == false)
        #expect(xcode.teamIdentifier == "Apple Software")
        #expect(xcode.signatureValid == true)
    }

    // MARK: - Signature failures

    @Test("unsigned or broken bundles surface signatureValid false without aborting scan")
    func brokenSignatureDoesNotAbort() async {
        let goodURL = URL(fileURLWithPath: "/Applications/Good.app")
        let brokenURL = URL(fileURLWithPath: "/Applications/Broken.app")

        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [goodURL, brokenURL]),
            reader: StubReader(
                metadata: [
                    goodURL.path: Self.meta(bundleID: "com.good", name: "Good", path: goodURL.path),
                    brokenURL.path: Self.meta(
                        bundleID: "com.broken",
                        name: "Broken",
                        path: brokenURL.path
                    ),
                ],
                sizes: [:]
            ),
            runningChecker: StubRunningChecker(running: []),
            signatureVerifier: StubVerifier(infos: [
                goodURL.path: CodeSignatureInfo(valid: true, teamIdentifier: "ABCD123456"),
                brokenURL.path: CodeSignatureInfo(valid: false, teamIdentifier: nil),
            ])
        )

        let apps = await scanner.scanApps()
        #expect(apps.count == 2)
        #expect(apps.first(where: { $0.bundleID == "com.broken" })?.signatureValid == false)
        #expect(apps.first(where: { $0.bundleID == "com.good" })?.signatureValid == true)
    }

    @Test("verifier returning .unknown produces signatureValid nil")
    func unknownSignature() async {
        let url = URL(fileURLWithPath: "/Applications/Opaque.app")
        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [url]),
            reader: StubReader(
                metadata: [url.path: Self.meta(bundleID: "com.opaque", name: "Opaque", path: url.path)],
                sizes: [:]
            ),
            runningChecker: StubRunningChecker(running: []),
            signatureVerifier: StubVerifier(infos: [:], defaultInfo: .unknown)
        )

        let apps = await scanner.scanApps()
        #expect(apps.count == 1)
        #expect(apps[0].signatureValid == nil)
        #expect(apps[0].teamIdentifier == nil)
    }

    // MARK: - System app detection

    @Test("bundles under /System/ are marked isSystemApp regardless of signature")
    func systemPathDetection() async {
        let url = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [url]),
            reader: StubReader(
                metadata: [url.path: Self.meta(bundleID: "com.apple.mail", name: "Mail", path: url.path)],
                sizes: [:]
            ),
            runningChecker: StubRunningChecker(running: []),
            signatureVerifier: StubVerifier(infos: [
                // Even with no team ID, the /System/ prefix wins
                url.path: CodeSignatureInfo(valid: true, teamIdentifier: nil)
            ])
        )

        let apps = await scanner.scanApps()
        #expect(apps.first?.isSystemApp == true)
    }

    @Test("Apple-signed apps installed in /Applications are NOT flagged isSystemApp")
    func appleSignedUserAppNotSystem() async {
        // Keynote ships in /Applications signed by Apple. It is user-installable
        // and must remain uninstallable — do not mark isSystemApp.
        let url = URL(fileURLWithPath: "/Applications/Keynote.app")
        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [url]),
            reader: StubReader(
                metadata: [
                    url.path: Self.meta(
                        bundleID: "com.apple.iWork.Keynote",
                        name: "Keynote",
                        path: url.path
                    ),
                ],
                sizes: [:]
            ),
            runningChecker: StubRunningChecker(running: []),
            signatureVerifier: StubVerifier(infos: [
                url.path: CodeSignatureInfo(valid: true, teamIdentifier: "APPLECOMPUTER")
            ])
        )

        let apps = await scanner.scanApps()
        #expect(apps.first?.isSystemApp == false)
    }

    // MARK: - Dedup

    @Test("bundles with the same bundleID are deduplicated, first-seen wins")
    func dedupByBundleID() async {
        let primaryURL = URL(fileURLWithPath: "/Applications/Slack.app")
        let duplicateURL = URL(fileURLWithPath: "/Users/foo/Downloads/Slack.app")

        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [primaryURL, duplicateURL]),
            reader: StubReader(
                metadata: [
                    primaryURL.path: Self.meta(
                        bundleID: "com.tinyspeck.slackmacgap",
                        name: "Slack",
                        path: primaryURL.path
                    ),
                    duplicateURL.path: Self.meta(
                        bundleID: "com.tinyspeck.slackmacgap",
                        name: "Slack",
                        path: duplicateURL.path
                    ),
                ],
                sizes: [:]
            ),
            runningChecker: StubRunningChecker(running: []),
            signatureVerifier: StubVerifier(infos: [:])
        )

        let apps = await scanner.scanApps()
        #expect(apps.count == 1)
        #expect(apps[0].bundlePath == primaryURL.path)
    }

    // MARK: - Unreadable bundles

    @Test("bundles that the reader returns nil for are skipped")
    func unreadableBundleSkipped() async {
        let goodURL = URL(fileURLWithPath: "/Applications/Good.app")
        let brokenURL = URL(fileURLWithPath: "/Applications/NoPlist.app")

        let scanner = DefaultAppScanner(
            enumerator: StubEnumerator(urls: [goodURL, brokenURL]),
            reader: StubReader(
                metadata: [
                    goodURL.path: Self.meta(bundleID: "com.good", name: "Good", path: goodURL.path)
                    // brokenURL has no metadata entry → reader returns nil
                ],
                sizes: [:]
            ),
            runningChecker: StubRunningChecker(running: []),
            signatureVerifier: StubVerifier(infos: [:])
        )

        let apps = await scanner.scanApps()
        #expect(apps.count == 1)
        #expect(apps[0].bundleID == "com.good")
    }

    // MARK: - Enumerator defaults

    @Test("DefaultAppBundleEnumerator default roots include /Applications and ~/Applications")
    func defaultSearchRoots() {
        let roots = DefaultAppBundleEnumerator.defaultSearchRoots()
        let paths = roots.map(\.path)
        #expect(paths.contains("/Applications"))
        #expect(paths.contains { $0.hasSuffix("/Applications") && $0 != "/Applications" })
    }
}
