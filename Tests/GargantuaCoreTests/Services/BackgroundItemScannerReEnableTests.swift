import Foundation
import Testing
@testable import GargantuaCore

// `.reEnabledByVendor` badge — cross-checks the audit trail's last successful
// launchctl action against the current launchd override DB state. Badge only;
// never a safety change. Stubs mirror BackgroundItemScannerOwningAppTests'
// file-scoped pattern but are re-declared locally per the task's guidance.
@Suite("BackgroundItemScanner — re-enabled by vendor")
struct BackgroundItemScannerReEnableTests {

    private static let plistPath = "/Users/me/Library/LaunchAgents/com.acme.tool.plist"

    // MARK: - (a)-(e) badge gating

    @Test("Audited disable (exit 0) + override false badges reEnabledByVendor")
    func disabledThenReEnabledBadges() {
        let scanner = makeScanner(
            auditEntries: [auditEntry(command: "disable", exitCode: 0)],
            disabledOverride: false
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.reasons.contains(.reEnabledByVendor) == true)
    }

    @Test("Audited disable + override true does not badge")
    func disabledStillDisabledNoBadge() {
        let scanner = makeScanner(
            auditEntries: [auditEntry(command: "disable", exitCode: 0)],
            disabledOverride: true
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.reasons.contains(.reEnabledByVendor) == false)
    }

    @Test("Audited disable + override nil (unknown) does not badge")
    func disabledOverrideUnknownNoBadge() {
        let scanner = makeScanner(
            auditEntries: [auditEntry(command: "disable", exitCode: 0)],
            disabledOverride: nil
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.reasons.contains(.reEnabledByVendor) == false)
    }

    @Test("Disable then later enable does not badge")
    func disableThenEnableNoBadge() {
        let scanner = makeScanner(
            auditEntries: [
                auditEntry(command: "disable", exitCode: 0),
                auditEntry(command: "enable", exitCode: 0),
            ],
            disabledOverride: false
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.reasons.contains(.reEnabledByVendor) == false)
    }

    @Test("Failed disable (exit 1) + override false does not badge")
    func failedDisableNoBadge() {
        let scanner = makeScanner(
            auditEntries: [auditEntry(command: "disable", exitCode: 1)],
            disabledOverride: false
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.reasons.contains(.reEnabledByVendor) == false)
    }

    @Test("Enable recorded with tolerated bootstrap exit 37 still clears — no false badge")
    func enableWithBootstrapAlreadyLoadedClears() {
        // A successful Gargantua enable can persist the bootstrap step's
        // tolerated exit 37 ("already loaded") as the primary command.
        // Attributing the user's own re-enable to a vendor would be worse
        // than missing a real vendor re-enable.
        let scanner = makeScanner(
            auditEntries: [
                auditEntry(command: "disable", exitCode: 0),
                auditEntry(command: "enable", exitCode: 37),
            ],
            disabledOverride: false
        )
        let item = try? #require(scanner.scan().items.first)
        #expect(item?.reasons.contains(.reEnabledByVendor) == false)
    }

    @Test("ANY enable attempt clears, even a failed one — enable already cleared the override")
    func failedEnableStillClears() {
        let entries = [
            auditEntry(command: "disable", exitCode: 0),
            auditEntry(command: "enable", exitCode: 5),
        ]
        let state = DefaultBackgroundItemScanner.lastDisabledByGargantua(entries)
        #expect(state[Self.plistPath] == false)
    }

    @Test("A delete entry clears the disable ledger — a reinstalled plist is a fresh install")
    func deleteClearsLedger() {
        let entries = [
            auditEntry(command: "disable", exitCode: 0),
            auditEntry(command: "delete", exitCode: nil, kind: .path),
        ]
        let state = DefaultBackgroundItemScanner.lastDisabledByGargantua(entries)
        #expect(state[Self.plistPath] == false)
    }

    // MARK: - (f) safety untouched

    @Test("Safety is identical with and without the audit entry")
    func safetyUnchangedByBadge() {
        let withBadge = makeScanner(
            auditEntries: [auditEntry(command: "disable", exitCode: 0)],
            disabledOverride: false
        )
        let withoutBadge = makeScanner(auditEntries: [], disabledOverride: false)

        let badgedItem = try? #require(withBadge.scan().items.first)
        let plainItem = try? #require(withoutBadge.scan().items.first)

        #expect(badgedItem?.reasons.contains(.reEnabledByVendor) == true)
        #expect(plainItem?.reasons.contains(.reEnabledByVendor) == false)
        #expect(badgedItem?.safety == plainItem?.safety)
    }

    // MARK: - (g) lastDisabledByGargantua unit tests

    @Test("Later entries win over earlier ones for the same path")
    func laterEntriesWin() {
        let entries = [
            auditEntry(command: "disable", exitCode: 0),
            auditEntry(command: "enable", exitCode: 0),
        ]
        let state = DefaultBackgroundItemScanner.lastDisabledByGargantua(entries)
        #expect(state[Self.plistPath] == false)
    }

    @Test("Empty file path is skipped entirely")
    func emptyPathSkipped() {
        let entry = auditEntry(command: "disable", exitCode: 0, path: "")
        let state = DefaultBackgroundItemScanner.lastDisabledByGargantua([entry])
        #expect(state.isEmpty)
    }

    @Test("Non-command kind entries are skipped")
    func nonCommandKindSkipped() {
        let entry = AuditEntry(
            tool: "native",
            command: "disable",
            files: [AuditFile(path: Self.plistPath, size: 0)],
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            bytesFreed: 0,
            kind: .path,
            commandExitCode: 0
        )
        let state = DefaultBackgroundItemScanner.lastDisabledByGargantua([entry])
        #expect(state.isEmpty)
    }

    // MARK: - Helpers

    private func auditEntry(
        command: String,
        exitCode: Int32?,
        path: String = plistPath,
        kind: AuditEntryKind = .command
    ) -> AuditEntry {
        AuditEntry(
            tool: "native",
            command: command,
            files: [AuditFile(path: path, size: 0)],
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            bytesFreed: 0,
            kind: kind,
            commandExitCode: exitCode
        )
    }

    private func makeScanner(
        auditEntries: [AuditEntry],
        disabledOverride: Bool?
    ) -> DefaultBackgroundItemScanner {
        let plist = LaunchdPlist(label: "com.acme.tool", program: "/usr/local/bin/tool")
        let launchd = [
            LaunchdItem(domain: .userAgent, plistPath: Self.plistPath, plist: plist),
        ]
        let runtimeState = LaunchdRuntimeState(
            isLoaded: true,
            pid: nil,
            lastExitStatus: nil,
            disabledOverride: disabledOverride
        )
        return DefaultBackgroundItemScanner(
            launchdIndex: StubLaunchdIndex(items: launchd),
            loginItems: StubLoginItems(enumeration: .empty),
            resolver: StubResolver(map: [:]),
            classifier: BackgroundItemSafetyClassifier(),
            explainer: BackgroundItemExplainer(),
            runtimeProvider: StubRuntimeProvider(stateToReturn: runtimeState),
            appResolver: NeverCalledOwningAppResolver(),
            auditEntries: { auditEntries },
            fileExists: { $0 == "/usr/local/bin/tool" },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

// MARK: - File-scoped stubs

private struct StubLaunchdIndex: LaunchdItemIndexing {
    let items: [LaunchdItem]
    func enumerate() -> [LaunchdItem] { items }
}

private struct StubLoginItems: LoginItemEnumerating {
    let enumeration: LoginItemEnumeration
    func enumerate() -> LoginItemEnumeration { enumeration }
}

private struct StubResolver: BinaryIdentityResolving {
    let map: [String: BinaryIdentity]
    func resolve(binaryPath: String) -> BinaryIdentity {
        map[binaryPath] ?? BinaryIdentity(binaryPath: binaryPath, vendor: .unsigned)
    }
}

private struct StubRuntimeProvider: LaunchdRuntimeStateProviding {
    let stateToReturn: LaunchdRuntimeState?
    func snapshot() -> LaunchdRuntimeSnapshot { .empty }
    func printDetail(label: String, source: BackgroundItemSource) -> LaunchdRuntimeDetail? { nil }
    func state(
        label: String,
        source: BackgroundItemSource,
        snapshot: LaunchdRuntimeSnapshot
    ) -> LaunchdRuntimeState? { stateToReturn }
}

/// This suite's item never resolves a bundle identifier or a well-known
/// vendor label prefix, so owning-app evidence is never consulted — a call
/// here would mean the scanner's skip-guard regressed.
private struct NeverCalledOwningAppResolver: OwningAppResolving {
    func isInstalled(bundleID: String) -> Bool {
        Issue.record("isInstalled should not be called")
        return false
    }

    func isAnyAppInstalled(bundleIDPrefix: String) -> Bool {
        Issue.record("isAnyAppInstalled should not be called")
        return false
    }

    func canConfirmAppAbsence() -> Bool {
        Issue.record("canConfirmAppAbsence should not be called")
        return true
    }
}
