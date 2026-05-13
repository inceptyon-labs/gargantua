import Foundation
import Testing
@testable import GargantuaCore

extension PrivilegedBackgroundItemValidatorTests {

    // MARK: - Plist Label binding (Codex finding)

    @Test("Filename matches but plist's internal Label differs — rejected")
    func filenameMatchesButInternalLabelDiffers() {
        let path = "/Library/LaunchDaemons/com.acme.tool.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(
                existing: [path],
                plistLabels: [path: "com.attacker.evil"]
            )
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
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

    @Test("Plist that can't be read is rejected (we don't trust filename alone)")
    func unreadablePlistRejected() {
        let path = "/Library/LaunchDaemons/com.acme.tool.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: PrivilegedBackgroundItemValidator.FileSystem(
                fileExists: { _, isDir in isDir?.pointee = false; return true },
                resolvedSymlinkPath: { $0 },
                plistLabel: { _ in nil }
            )
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.acme.tool",
            plistPath: path
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.unreadablePlist(path)) {
            try validator.validate(request)
        }
    }

    // MARK: - Path required for all ops

    @Test("disableDaemon now requires a plist path witness")
    func disableRequiresPlistPath() {
        let validator = PrivilegedBackgroundItemValidator(fileSystem: Self.fileSystem())
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.acme.tool",
            plistPath: nil
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.missingPlistPath) {
            try validator.validate(request)
        }
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
}
