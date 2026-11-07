import Foundation
import Testing
@testable import GargantuaCore

/// Covers the argument policy that keeps an allowlisted general-purpose
/// launcher (`xcrun`) from being turned into arbitrary execution by a command
/// rule. The bundled `simctl_delete_unavailable` rule must keep working; every
/// launcher escape (`--run`, `-r`, a path sub-tool, a non-allowlisted
/// sub-tool) must be rejected.
@Suite("CommandActionToolResolver argument policy")
struct CommandActionToolResolverPolicyTests {

    @Test("xcrun with an allowlisted sub-tool is permitted")
    func allowsAllowlistedSubcommand() throws {
        try CommandActionToolResolver.validateArguments(
            tool: "xcrun",
            arguments: ["simctl", "delete", "unavailable"]
        )
    }

    @Test("xcrun --run is rejected (arbitrary launcher)")
    func rejectsRunFlag() {
        #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
            try CommandActionToolResolver.validateArguments(
                tool: "xcrun",
                arguments: ["--run", "/tmp/evil"]
            )
        }
    }

    @Test("xcrun -r is rejected (arbitrary launcher short flag)")
    func rejectsRunShortFlag() {
        #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
            try CommandActionToolResolver.validateArguments(
                tool: "xcrun",
                arguments: ["-r", "/tmp/evil"]
            )
        }
    }

    @Test("xcrun with a path sub-tool is rejected")
    func rejectsPathSubtool() {
        #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
            try CommandActionToolResolver.validateArguments(
                tool: "xcrun",
                arguments: ["/usr/bin/env", "sh"]
            )
        }
        #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
            try CommandActionToolResolver.validateArguments(
                tool: "xcrun",
                arguments: ["./evil"]
            )
        }
    }

    @Test("xcrun with a non-allowlisted sub-tool is rejected")
    func rejectsNonAllowlistedSubtool() {
        #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
            try CommandActionToolResolver.validateArguments(
                tool: "xcrun",
                arguments: ["ld", "-o", "/tmp/out"]
            )
        }
    }

    @Test("xcrun with no arguments is rejected")
    func rejectsEmptyArguments() {
        #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
            try CommandActionToolResolver.validateArguments(tool: "xcrun", arguments: [])
        }
    }

    @Test("tmutil local-snapshot verbs are permitted")
    func allowsTmutilSnapshotVerbs() throws {
        try CommandActionToolResolver.validateArguments(tool: "tmutil", arguments: ["listlocalsnapshots", "/"])
        try CommandActionToolResolver.validateArguments(tool: "tmutil", arguments: ["deletelocalsnapshots", "/"])
    }

    @Test("tmutil verbs that touch backups or settings are rejected")
    func rejectsOtherTmutilVerbs() {
        for arguments in [["delete", "-d", "/Volumes/Backup"], ["disable"], ["setdestination", "/Volumes/X"], []] {
            #expect(throws: CommandActionToolResolver.ArgumentPolicyError.self) {
                try CommandActionToolResolver.validateArguments(tool: "tmutil", arguments: arguments)
            }
        }
    }

    @Test("non-launcher tools are unconstrained")
    func otherToolsUnconstrained() throws {
        // A path argument is perfectly normal for e.g. `docker`; the policy
        // must not touch tools other than the constrained launchers.
        try CommandActionToolResolver.validateArguments(
            tool: "docker",
            arguments: ["system", "prune", "-f"]
        )
        try CommandActionToolResolver.validateArguments(
            tool: "pnpm",
            arguments: ["store", "prune"]
        )
    }
}
