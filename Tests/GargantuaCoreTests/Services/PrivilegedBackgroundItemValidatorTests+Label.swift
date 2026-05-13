import Foundation
import Testing
@testable import GargantuaCore

extension PrivilegedBackgroundItemValidatorTests {

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

    @Test("Plain alphanumeric label with a witness plist on disk is accepted")
    func plainLabelAccepted() throws {
        let path = "/Library/LaunchDaemons/com.acme.tool.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: [path])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.acme.tool",
            plistPath: path
        )
        try validator.validate(request)
    }

    // MARK: - Operation-specific allowed directories (Codex finding)

    @Test("disableDaemon refuses /Library/LaunchAgents — daemon ops are daemons-only")
    func disableDaemonRefusesLaunchAgents() {
        let path = "/Library/LaunchAgents/com.acme.tool.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: [path])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .disableDaemon,
            label: "com.acme.tool",
            plistPath: path
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.rejectedPath(path)) {
            try validator.validate(request)
        }
    }

    @Test("bootstrapDaemon refuses /Library/LaunchAgents")
    func bootstrapDaemonRefusesLaunchAgents() {
        let path = "/Library/LaunchAgents/com.acme.tool.plist"
        let validator = PrivilegedBackgroundItemValidator(
            fileSystem: Self.fileSystem(existing: [path])
        )
        let request = PrivilegedBackgroundItemRequest(
            operation: .bootstrapDaemon,
            label: "com.acme.tool",
            plistPath: path
        )
        #expect(throws: PrivilegedBackgroundItemValidationError.rejectedPath(path)) {
            try validator.validate(request)
        }
    }

    @Test("trashLaunchPlist accepts /Library/LaunchAgents (system agents are root-owned files)")
    func trashAcceptsLaunchAgents() throws {
        let path = "/Library/LaunchAgents/com.acme.tool.plist"
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
}
