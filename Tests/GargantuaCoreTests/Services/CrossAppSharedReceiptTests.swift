import Foundation
import Testing
@testable import GargantuaCore

/// Cross-app shared-receipt cases: one installer drops files used by multiple
/// still-installed apps (Adobe Creative Cloud, MS Office shapes). Receipts are
/// evidence, not permission — receipt-derived items must classify as `.review`
/// or `.protected_` regardless of ownership claim, and provenance must point
/// at the *receipt's* package ID, not the uninstall target's bundle ID.
@Suite("Cross-app shared-receipt evidence")
struct CrossAppSharedReceiptTests {

    private final class StubRunner: ProcessRunner, @unchecked Sendable {
        let outputs: [[String]: ProcessOutput]

        init(outputs: [[String]: ProcessOutput]) {
            self.outputs = outputs
        }

        func run(executable: URL, arguments: [String]) throws -> ProcessOutput {
            try run(executable: executable, arguments: arguments, timeout: nil)
        }

        func run(executable _: URL, arguments: [String], timeout _: TimeInterval?) throws -> ProcessOutput {
            outputs[arguments] ?? ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CrossAppSharedReceiptTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func makeFile(_ relative: String, contents: String = "x") throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// Stub spec for one package's `pkgutil` triple (`--pkg-info` + `--files`).
    private struct PkgStub {
        let id: String
        let version: String
        let paths: [String]
    }

    /// Build a `StubRunner` from a list of `PkgStub`s. Emits `--pkgs` listing
    /// every id, plus matched `--pkg-info` and `--files` outputs. Paths are
    /// emitted with the leading `/` stripped so the expander resolves them
    /// against `volume: /` / `location: /`.
    private static func stubRunner(_ stubs: [PkgStub]) -> StubRunner {
        var outputs: [[String]: ProcessOutput] = [:]
        outputs[["--pkgs"]] = ProcessOutput(
            stdout: stubs.map(\.id).joined(separator: "\n"),
            stderr: "",
            exitCode: 0
        )
        for stub in stubs {
            outputs[["--pkg-info", stub.id]] = ProcessOutput(
                stdout: """
                package-id: \(stub.id)
                version: \(stub.version)
                volume: /
                location: /
                """,
                stderr: "",
                exitCode: 0
            )
            outputs[["--files", stub.id]] = ProcessOutput(
                stdout: stub.paths.map { String($0.dropFirst()) }.joined(separator: "\n"),
                stderr: "",
                exitCode: 0
            )
        }
        return StubRunner(outputs: outputs)
    }

    /// Build a receipt-evidence-enabled scanner around `runner` with a
    /// permissive (empty) `ProtectedRootPolicy` so the test controls every
    /// classification gate explicitly.
    private static func scanner(
        rules: [RemnantRule] = [],
        runner: StubRunner
    ) -> RemnantScanner {
        RemnantScanner(rules: rules).withReceiptEvidence(
            expander: PackageReceiptExpander(runner: runner),
            builder: ReceiptRemnantBuilder(protectedRoots: ProtectedRootPolicy(entries: []))
        )
    }

    private static func app(_ bundleID: String, _ name: String) -> AppInfo {
        AppInfo(bundleID: bundleID, name: name, bundlePath: "/Applications/\(name).app")
    }

    // MARK: - Adobe Creative Cloud shape

    @Test("Adobe shape: shared user-library path classifies as .review across sibling apps")
    func adobeSharedSupportPathStaysReview() throws {
        let fixture = try Fixture()
        // Adobe Creative Cloud drops a shared support file that both Photoshop
        // and Illustrator depend on. The user is uninstalling Photoshop, but
        // the file is owned (per receipt) by `com.adobe.acc.installer`.
        let sharedFile = try fixture.makeFile(
            "Library/Application Support/Adobe/AdobeApplicationManager/shared.bin",
            contents: "shared adobe state"
        )

        let runner = Self.stubRunner([
            PkgStub(id: "com.adobe.Photoshop", version: "25.0.0", paths: []),
            PkgStub(id: "com.adobe.acc.installer", version: "5.10", paths: [sharedFile.path]),
        ])
        let plan = Self.scanner(runner: runner).plan(
            for: Self.app("com.adobe.Photoshop", "Adobe Photoshop"),
            includeAppBundle: false
        )

        let item = try #require(plan.remnants.first { $0.path == sharedFile.path })
        // Trust Layer: receipt-derived shared paths are NEVER `.safe`. Default
        // is `.review` regardless of ownership claim. Provenance points at the
        // receipt's package id (the shared installer) — not Photoshop's bundle
        // id — so the user can see this came from the shared installer.
        #expect(item.safety == .review)
        #expect(item.ruleID == "pkgutil-bom:com.adobe.acc.installer")
        #expect(item.explanation.contains("com.adobe.acc.installer"))
        #expect(item.tags.contains("pkgutil-bom"))
    }

    @Test("Adobe shape: same path listed in two sibling receipts dedupes to a single row")
    func adobeDuplicatePathAcrossReceiptsDedups() throws {
        let fixture = try Fixture()
        let sharedFile = try fixture.makeFile(
            "Library/Application Support/Adobe/Common/Plug-ins/CommonPlugin.plugin",
            contents: "shared plugin"
        )

        // Both Photoshop and Illustrator receipts list the same shared plugin
        // path. Only one row should surface; first receipt processed wins.
        let runner = Self.stubRunner([
            PkgStub(id: "com.adobe.Photoshop", version: "25.0.0", paths: [sharedFile.path]),
            PkgStub(id: "com.adobe.Illustrator", version: "28.0.0", paths: [sharedFile.path]),
        ])
        let plan = Self.scanner(runner: runner).plan(
            for: Self.app("com.adobe.Photoshop", "Adobe Photoshop"),
            includeAppBundle: false
        )

        let hits = plan.remnants.filter { $0.path == sharedFile.path }
        #expect(hits.count == 1)
        #expect(hits.first?.ruleID == "pkgutil-bom:com.adobe.Photoshop")
    }

    @Test("Adobe shape: reverse-DNS over-match surfaces sibling-app files but never as .safe")
    func adobeReverseDNSOverMatchStaysReview() throws {
        let fixture = try Fixture()
        // `com.adobe.illustrator` is the only receipt and ships its own owned
        // file. Photoshop's bundle id shares the `com.adobe.` reverse-DNS
        // prefix, so the matcher pulls in this sibling receipt. Trust Layer
        // must keep the row at `.review` and pin provenance to the *real*
        // owning pkgID — making the cross-app source visible.
        let illustratorFile = try fixture.makeFile(
            "Library/Application Support/Adobe/Illustrator 2024/illustrator.dat",
            contents: "illustrator"
        )

        let runner = Self.stubRunner([
            PkgStub(id: "com.adobe.illustrator", version: "28.0.0", paths: [illustratorFile.path]),
        ])
        let plan = Self.scanner(runner: runner).plan(
            for: Self.app("com.adobe.Photoshop", "Adobe Photoshop"),
            includeAppBundle: false
        )

        let item = try #require(plan.remnants.first { $0.path == illustratorFile.path })
        #expect(item.safety == .review)
        #expect(item.ruleID == "pkgutil-bom:com.adobe.illustrator")
        #expect(item.explanation.contains("com.adobe.illustrator"))
    }

    // MARK: - MS Office shape

    @Test("MS Office shape: shared system path upgrades to .protected_ regardless of ownership")
    func msOfficeSharedLaunchDaemonProtected() throws {
        // MS Office's licensing helper is shared across Word, Excel, PowerPoint,
        // Outlook. Use the real `/Library/LaunchDaemons/` path the Office
        // installer drops; if it doesn't exist (most CI machines), the receipt
        // builder drops it as a stale-receipt case which is itself the correct
        // Trust Layer behavior.
        let sharedDaemon = "/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist"
        let pathExists = FileManager.default.fileExists(atPath: sharedDaemon)

        let runner = Self.stubRunner([
            PkgStub(id: "com.microsoft.package.Microsoft_Word.app", version: "16.80", paths: []),
            PkgStub(id: "com.microsoft.office.licensing", version: "16.80", paths: [sharedDaemon]),
        ])
        let plan = Self.scanner(runner: runner).plan(
            for: Self.app("com.microsoft.Word", "Microsoft Word"),
            includeAppBundle: false
        )

        if pathExists {
            // Shared system path overrides any ownership claim from the BOM.
            let item = try #require(plan.remnants.first { $0.path == sharedDaemon })
            #expect(item.safety == .protected_)
            #expect(item.explanation.contains("Shared system path"))
            #expect(item.ruleID == "pkgutil-bom:com.microsoft.office.licensing")
        } else {
            // No Office installed → stale receipt entry, silently dropped.
            #expect(plan.remnants.contains { $0.path == sharedDaemon } == false)
        }
    }

    @Test("MS Office shape: shared user-library path classifies as .review across sibling apps")
    func msOfficeSharedFontCacheStaysReview() throws {
        let fixture = try Fixture()
        // Shared Office font cache used by Word, Excel, PowerPoint. User is
        // uninstalling Word; the cache is owned by the licensing receipt.
        let sharedCache = try fixture.makeFile(
            "Library/Group Containers/UBF8T346G9.Office/FontCache.dat",
            contents: "font cache"
        )

        let runner = Self.stubRunner([
            PkgStub(id: "com.microsoft.package.Microsoft_Word.app", version: "16.80", paths: []),
            PkgStub(id: "com.microsoft.office.licensing", version: "16.80", paths: [sharedCache.path]),
        ])
        let plan = Self.scanner(runner: runner).plan(
            for: Self.app("com.microsoft.Word", "Microsoft Word"),
            includeAppBundle: false
        )

        let item = try #require(plan.remnants.first { $0.path == sharedCache.path })
        #expect(item.safety == .review)
        #expect(item.ruleID == "pkgutil-bom:com.microsoft.office.licensing")
        #expect(item.explanation.contains("com.microsoft.office.licensing"))
    }

    // MARK: - YAML rule precedence over receipt for shared paths

    @Test("YAML rule with explicit safety wins over receipt classification for cross-app shared path")
    func yamlRuleWinsOverReceiptForSharedPath() throws {
        let fixture = try Fixture()
        let sharedFile = try fixture.makeFile(
            "Library/Application Support/Adobe/Common/shared.bin",
            contents: "shared"
        )

        // A YAML remnant rule explicitly tags this path as `.safe` for
        // Photoshop. The receipt would default it to `.review`. Per existing
        // dedup behavior, the rule output is emitted first and the receipt
        // path is suppressed.
        let rule = RemnantRule(
            id: "adobe_common_shared",
            name: "Adobe shared common",
            category: .supportFiles,
            pathTemplates: [sharedFile.path],
            safety: .safe,
            confidence: 90,
            explanation: "Shared Adobe common files; rule-classified.",
            source: SourceAttribution(name: "Adobe", bundleID: "com.adobe.Photoshop"),
            appliesTo: AppScope(bundleIDs: ["com.adobe.Photoshop"])
        )

        let runner = Self.stubRunner([
            PkgStub(id: "com.adobe.acc.installer", version: "5.10", paths: [sharedFile.path]),
        ])
        let plan = Self.scanner(rules: [rule], runner: runner).plan(
            for: Self.app("com.adobe.Photoshop", "Adobe Photoshop"),
            includeAppBundle: false
        )

        let hits = plan.remnants.filter { $0.path == sharedFile.path }
        #expect(hits.count == 1)
        let item = try #require(hits.first)
        #expect(item.ruleID == "adobe_common_shared")
        #expect(!item.tags.contains("pkgutil-bom"))
    }
}
