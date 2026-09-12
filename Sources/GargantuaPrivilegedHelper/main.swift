import Foundation
import GargantuaCore

private final class PrivilegedHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedUninstallXPCService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Framework-enforced, race-free client authentication: the connection
        // rejects messages from any peer that doesn't satisfy the requirement,
        // evaluated against the peer's audit token rather than its PID — so there
        // is no PID-reuse TOCTOU window like a manual SecCodeCopyGuestWithAttributes
        // check has. Binds the caller to our app identifier + Developer ID Team ID.
        connection.setCodeSigningRequirement(PrivilegedHelperConfiguration.codeSigningRequirement)
        HelperLog.write("accepted connection from pid \(connection.processIdentifier)")
        connection.exportedInterface = NSXPCInterface(with: PrivilegedUninstallXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class PrivilegedUninstallXPCService: NSObject, PrivilegedUninstallXPCProtocol {
    private let backgroundItemValidator = PrivilegedBackgroundItemValidator()

    func helperVersion(withReply reply: @escaping (Int) -> Void) {
        reply(PrivilegedHelperConfiguration.helperVersion)
    }

    func moveItemsToTrash(
        requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let request = try PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedUninstallRequest.self,
                from: requestData
            )
            // The target user is the connection's audit-token-derived effective
            // uid, NOT `request.invokingUserID` — a client-supplied field a
            // compromised (but validly signed) peer could set to any uid (e.g.
            // 0) to redirect the Trash move + recursive chown onto root-owned
            // or another user's paths. `effectiveUserIdentifier` is set by the
            // kernel from the peer's audit token and cannot be spoofed. Falls
            // back to `nil` (root Trash) only if the connection is unavailable.
            let invokingUserID = NSXPCConnection.current()?.effectiveUserIdentifier
            let results = request.items.map { remove($0, invokingUserID: invokingUserID) }
            let response = PrivilegedUninstallResponse(items: results)
            reply(try PrivilegedUninstallXPCCodec.encoder.encode(response))
        } catch {
            let response = PrivilegedUninstallErrorResponse(error: error.localizedDescription)
            let data = (try? PrivilegedUninstallXPCCodec.encoder.encode(response)) ?? Data()
            reply(data)
        }
    }

    func performBackgroundItemAction(
        requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        let response: PrivilegedBackgroundItemResponse
        do {
            let request = try PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedBackgroundItemRequest.self,
                from: requestData
            )
            response = handleBackgroundItem(request)
        } catch {
            // Decode failures use the existing uninstall error envelope so
            // the client can render a generic helper failure with the same
            // path it already handles.
            let envelope = PrivilegedUninstallErrorResponse(error: error.localizedDescription)
            let data = (try? PrivilegedUninstallXPCCodec.encoder.encode(envelope)) ?? Data()
            reply(data)
            return
        }
        let data = (try? PrivilegedUninstallXPCCodec.encoder.encode(response)) ?? Data()
        reply(data)
    }

    private func handleBackgroundItem(
        _ request: PrivilegedBackgroundItemRequest
    ) -> PrivilegedBackgroundItemResponse {
        do {
            try backgroundItemValidator.validate(request)
        } catch {
            HelperLog.write(
                "background-item validation rejected \(request.operation.rawValue) "
                    + "label=\(request.label) path=\(request.plistPath ?? "<nil>"): \(error.localizedDescription)"
            )
            return PrivilegedBackgroundItemResponse(
                id: request.id,
                succeeded: false,
                error: error.localizedDescription
            )
        }

        switch request.operation {
        case .bootoutDaemon, .disableDaemon, .enableDaemon, .bootstrapDaemon:
            guard let arguments = PrivilegedBackgroundItemValidator.launchctlArguments(
                for: request.operation,
                label: request.label,
                plistPath: request.plistPath
            ) else {
                return PrivilegedBackgroundItemResponse(
                    id: request.id,
                    succeeded: false,
                    error: "Helper could not build launchctl arguments for \(request.operation.rawValue)."
                )
            }
            let result = runLaunchctl(arguments: arguments)
            HelperLog.write(
                "launchctl \(arguments.joined(separator: " ")) exit=\(result.exitCode)"
            )
            return PrivilegedBackgroundItemResponse(
                id: request.id,
                succeeded: result.succeeded,
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                trashPath: nil,
                error: result.succeeded ? nil : (result.stderr.isEmpty ? "launchctl exited \(result.exitCode)" : result.stderr)
            )
        case .trashLaunchPlist:
            guard let path = request.plistPath else {
                return PrivilegedBackgroundItemResponse(
                    id: request.id,
                    succeeded: false,
                    error: "Helper missing plist path for trash op."
                )
            }
            // Defense-in-depth: even if a compromised signed client skipped
            // the app-side "disable first" gate, the helper boots the job
            // out of system before trashing the plist. bootout against an
            // unloaded job is a no-op (exit 36 / "could not find").
            // LaunchAgents in `/Library/LaunchAgents/` are controlled in
            // `gui/<uid>` rather than `system`, so we limit the bootout
            // safety net to the daemons sub-tree we actually loaded as root.
            if path.hasPrefix("/Library/LaunchDaemons/") {
                let preBootout = DefaultLaunchctlRunner().run(["bootout", "system/\(request.label)"])
                HelperLog.write(
                    "trashLaunchPlist pre-bootout system/\(request.label) exit=\(preBootout.exitCode)"
                )
            }
            do {
                var trashURL: NSURL?
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path),
                    resultingItemURL: &trashURL
                )
                return PrivilegedBackgroundItemResponse(
                    id: request.id,
                    succeeded: true,
                    trashPath: (trashURL as URL?)?.path
                )
            } catch {
                HelperLog.write("trashLaunchPlist failed for \(path): \(error.localizedDescription)")
                return PrivilegedBackgroundItemResponse(
                    id: request.id,
                    succeeded: false,
                    error: error.localizedDescription
                )
            }
        }
    }

    private func runLaunchctl(arguments: [String]) -> LaunchctlResult {
        DefaultLaunchctlRunner().run(arguments)
    }

    private func remove(
        _ item: PrivilegedUninstallItem,
        invokingUserID: UInt32?
    ) -> PrivilegedUninstallItemResult {
        do {
            switch item.operation {
            case .moveToTrash:
                let url = try validate(item)
                let trashURL = try moveToTrash(url, invokingUserID: invokingUserID)
                return PrivilegedUninstallItemResult(
                    id: item.id,
                    path: item.path,
                    succeeded: true,
                    trashPath: trashURL.path
                )
            case .deleteFromTrash:
                let url = try validateTrashChild(item, invokingUserID: invokingUserID)
                try FileManager.default.removeItem(at: url)
                // Permanently removed (it was already in the Trash) — no trashPath.
                return PrivilegedUninstallItemResult(id: item.id, path: item.path, succeeded: true)
            }
        } catch {
            return PrivilegedUninstallItemResult(
                id: item.id,
                path: item.path,
                succeeded: false,
                error: error.localizedDescription
            )
        }
    }

    /// Validate that `item.path` is a direct child of the invoking user's own
    /// `~/.Trash`, the only place `deleteFromTrash` is permitted to act. The
    /// Trash directory is resolved from the UID via `getpwuid` (not a caller-
    /// supplied path), and the entry is removed as-is — a symlink entry is
    /// unlinked, never followed — so this can't be tricked into deleting outside
    /// the user's Trash.
    private func validateTrashChild(
        _ item: PrivilegedUninstallItem,
        invokingUserID: UInt32?
    ) throws -> URL {
        guard let uid = invokingUserID, let pw = getpwuid(uid) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }
        let home = String(cString: pw.pointee.pw_dir)
        let trashDir = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL

        let standardized = URL(fileURLWithPath: item.path).standardizedFileURL
        guard PrivilegedRemovabilityPolicy.canonical(standardized.path)
            == PrivilegedRemovabilityPolicy.canonical(item.path) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }
        guard standardized.deletingLastPathComponent().standardizedFileURL.path == trashDir.path else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw PrivilegedHelperError.missingPath(item.path)
        }
        return standardized
    }

    /// Move `url` into the invoking user's Trash and hand them ownership, so the
    /// removed item is visible and restorable in Finder and they can empty it
    /// without another auth prompt. Falls back to the root Trash (`trashItem`)
    /// when the user can't be resolved — same as the prior behavior.
    private func moveToTrash(_ url: URL, invokingUserID: UInt32?) throws -> URL {
        guard let uid = invokingUserID, let pw = getpwuid(uid) else {
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            return (trashURL as URL?) ?? url
        }
        let home = String(cString: pw.pointee.pw_dir)
        let gid = pw.pointee.pw_gid
        let trashDir = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let destination = collisionFreeDestination(for: url, in: trashDir)
        try FileManager.default.moveItem(at: url, to: destination)
        chownRecursively(destination, uid: uid, gid: gid)
        return destination
    }

    private func collisionFreeDestination(for url: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let first = directory.appendingPathComponent(url.lastPathComponent)
        guard fm.fileExists(atPath: first.path) else { return first }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// `lchown` the moved item (and every descendant) to the user. `lchown` does
    /// not follow symlinks, so a symlink in the tree can't redirect ownership of
    /// a file outside it. A multiply-linked regular file is skipped: `validate`
    /// already rejects a hard-linked top-level file, but a moved *directory*
    /// could still contain one (planted inside a world-writable allowlisted
    /// tree), and chowning it would transfer ownership of the linked-to inode.
    private func chownRecursively(_ url: URL, uid: UInt32, gid: UInt32) {
        chownIfSingleLink(url.path, uid: uid, gid: gid)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for case let child as URL in enumerator {
            chownIfSingleLink(child.path, uid: uid, gid: gid)
        }
    }

    /// `lchown` unless the path is a regular file with more than one hard link.
    private func chownIfSingleLink(_ path: String, uid: UInt32, gid: UInt32) {
        if PrivilegedRemovabilityPolicy.shared.isMultiplyLinkedRegularFile(path: path) {
            HelperLog.write("skipped chown of multiply-linked file: \(path)")
            return
        }
        lchown(path, uid, gid)
    }

    private func validate(_ item: PrivilegedUninstallItem) throws -> URL {
        guard item.operation == .moveToTrash else {
            throw PrivilegedHelperError.unsupportedOperation(item.operation.rawValue)
        }

        let url = URL(fileURLWithPath: item.path)
        let standardized = url.standardizedFileURL
        // Compare on the canonical (firmlink-collapsed) form: macOS rewrites an
        // existing /private/var path to /var, which is not path trickery and must
        // not be rejected. Real `..`/symlink redirection still fails these guards.
        guard PrivilegedRemovabilityPolicy.canonical(standardized.path)
            == PrivilegedRemovabilityPolicy.canonical(item.path) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }

        let symlinkResolved = standardized.resolvingSymlinksInPath()
        guard PrivilegedRemovabilityPolicy.canonical(symlinkResolved.path)
            == PrivilegedRemovabilityPolicy.canonical(standardized.path) else {
            throw PrivilegedHelperError.symlinkRejected(item.path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw PrivilegedHelperError.missingPath(item.path)
        }

        // A regular file with more than one hard link is never a legitimate
        // cleanup target here. The move-to-Trash below preserves the inode
        // (same volume) and `chownRecursively` then `lchown`s it to the invoking
        // user — so a second link into a root-owned file (e.g. an unprivileged
        // user hardlinking /etc/sudoers into world-writable /private/tmp, which
        // this helper's allowlist covers) would transfer ownership of that
        // inode to the user. The symlink guard above does not catch this: a hard
        // link is not a symlink, so `resolvingSymlinksInPath` leaves it
        // unchanged. Genuine regenerable temp/cache files have `st_nlink == 1`.
        if !isDirectory.boolValue,
           PrivilegedRemovabilityPolicy.shared.isMultiplyLinkedRegularFile(path: standardized.path) {
            throw PrivilegedHelperError.hardlinkRejected(item.path)
        }

        guard isAllowed(standardized, isDirectory: isDirectory.boolValue) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }

        return standardized
    }

    private func isAllowed(_ url: URL, isDirectory: Bool) -> Bool {
        // Single source of truth, shared with the app via GargantuaCore so the
        // scan-time view-only marking and the root-side enforcement can't drift.
        PrivilegedRemovabilityPolicy.shared.allows(path: url.path, isDirectory: isDirectory)
    }
}

private enum HelperLog {
    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

private enum PrivilegedHelperError: Error, LocalizedError {
    case unsupportedOperation(String)
    case rejectedPath(String)
    case symlinkRejected(String)
    case hardlinkRejected(String)
    case missingPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let operation):
            "Unsupported privileged helper operation: \(operation)"
        case .rejectedPath(let path):
            "Privileged helper rejected path: \(path)"
        case .symlinkRejected(let path):
            "Privileged helper rejected symlink path: \(path)"
        case .hardlinkRejected(let path):
            "Privileged helper rejected multiply-linked file: \(path)"
        case .missingPath(let path):
            "Privileged helper path does not exist: \(path)"
        }
    }
}

private let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.helperBundleID)
private let delegate = PrivilegedHelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
