import Foundation
import Testing
@testable import GargantuaCore

@Suite("PrivilegedBackgroundItemValidator")
struct PrivilegedBackgroundItemValidatorTests {

    // MARK: - Stub filesystem

    private static func fileSystem(
        existing: Set<String> = [],
        symlinks: [String: String] = [:]
    ) -> PrivilegedBackgroundItemValidator.FileSystem {
        let existing = existing
        let symlinks = symlinks
        return PrivilegedBackgroundItemValidator.FileSystem(
            fileExists: { path, isDir in
                if existing.contains(path) {
                    isDir?.pointee = false
                    return true
                }
                return false
            },
            resolvedSymlinkPath: { path in
                symlinks[path] ?? path
            }
        )
    }

    // MARK: - Label format

    @Test("Empty label is rejected")
    func emptyLabelRejected() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: ""
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.invalidLabel("")) {
            try validator.validate(request)
        }
    }

    @Test("Labels with path separators are rejected")
    func slashLabelRejected() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.evil/foo"
        )
        #expect(throws: (any Error).self) { try validator.validate(request) }
    }

    @Test("Labels with parent traversal are rejected")
    func dotDotLabelRejected() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "../etc/passwd"
        )
        #expect(throws: (any Error).self) { try validator.validate(request) }
    }

    @Test("Labels with whitespace are rejected (would break launchctl args)")
    func whitespaceLabelRejected() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.acme thing"
        )
        #expect(throws: (any Error).self) { try validator.validate(request) }
    }

    @Test("Apple-namespaced labels are always rejected")
    func appleLabelsRejected() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.apple.coreduetd"
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.appleLabelRejected("com.apple.coreduetd")) {
            try validator.validate(request)
        }
    }

    @Test("Bare alphanumeric label is accepted for launchctl-only ops")
    func plainLabelAccepted() throws {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.acme.tool"
        )
        try validator.validate(request)
    }

    // MARK: - Path validation

    @Test("Trash op with path under /System is rejected")
    func systemPathRejected() {
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: ["/System/Library/LaunchDaemons/com.acme.tool.plist"])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: "/System/Library/LaunchDaemons/com.acme.tool.plist"
        )
        #expect(throws: (any Error).self) { try validator.validate(request) }
    }

    @Test("Trash op with parent traversal is rejected")
    func parentTraversalRejected() {
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: ["/Library/LaunchDaemons/../etc/passwd"])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: "/Library/LaunchDaemons/../etc/passwd"
        )
        #expect(throws: (any Error).self) { try validator.validate(request) }
    }

    @Test("Trash op with symlink target is rejected")
    func symlinkRejected() {
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(
                existing: ["/Library/LaunchDaemons/com.acme.tool.plist"],
                symlinks: ["/Library/LaunchDaemons/com.acme.tool.plist": "/etc/passwd"]
            )
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist"
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.symlinkRejected(
            "/Library/LaunchDaemons/com.acme.tool.plist"
        )) {
            try validator.validate(request)
        }
    }

    @Test("Label and plist filename must agree")
    func labelPathMismatchRejected() {
        let path = "/Library/LaunchDaemons/com.evil.bar.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: [path])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: path
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.labelPathMismatch(
            label: "com.acme.tool",
            path: path
        )) {
            try validator.validate(request)
        }
    }

    @Test("Trash op with missing path is rejected")
    func missingPathRejected() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist"
        )
        #expect(throws: (any Error).self) { try validator.validate(request) }
    }

    @Test("Trash op with valid plist under LaunchDaemons is accepted")
    func validDaemonPlistAccepted() throws {
        let path = "/Library/LaunchDaemons/com.acme.tool.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: [path])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: path
        )
        try validator.validate(request)
    }

    @Test("Trash op with valid plist under LaunchAgents is accepted")
    func validAgentPlistAccepted() throws {
        let path = "/Library/LaunchAgents/com.acme.helper.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: [path])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .trashLaunchPlist,
            label: "com.acme.helper",
            plistPath: path
        )
        try validator.validate(request)
    }

    @Test("bootstrap requires a plist path that exists")
    func bootstrapRequiresPlist() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .bootstrapDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.missingPlistPath) {
            try validator.validate(request)
        }
    }

    // MARK: - Argument shape

    @Test("launchctl arguments have the expected shape")
    func argumentShape() {
        let bootout = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .bootoutDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(bootout == ["bootout", "system/com.acme.tool"])

        let disable = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .disableDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(disable == ["disable", "system/com.acme.tool"])

        let enable = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .enableDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(enable == ["enable", "system/com.acme.tool"])

        let bootstrap = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .bootstrapDaemon,
            label: "com.acme.tool",
            plistPath: "/Library/LaunchDaemons/com.acme.tool.plist"
        )
        #expect(bootstrap == ["bootstrap", "system", "/Library/LaunchDaemons/com.acme.tool.plist"])

        // Trash op has no launchctl arguments — the helper handles it via
        // FileManager.trashItem instead.
        let trash = PrivilegedBackgroundItemValidator.launchctlArguments(
            for: .trashLaunchPlist,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(trash == nil)
    }
}
