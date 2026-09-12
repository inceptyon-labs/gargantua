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
                try deleteFromTrash(item, invokingUserID: invokingUserID)
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

    /// Permanently remove a direct child of the invoking user's own `~/.Trash`.
    ///
    /// The Trash directory is pinned by descriptor (`getpwuid` for the home, then
    /// `O_NOFOLLOW` on `.Trash`), and the removal runs with `unlinkat` relative
    /// to that descriptor. So even if the user replaces `~/.Trash` with a symlink
    /// to a system directory, root cannot be tricked into deleting outside the
    /// real Trash — the pinned fd never traverses the swapped link, and a
    /// symlink entry is unlinked as the link, never followed.
    private func deleteFromTrash(
        _ item: PrivilegedUninstallItem,
        invokingUserID: UInt32?
    ) throws {
        guard let uid = invokingUserID, let pw = getpwuid(uid) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }
        let home = String(cString: pw.pointee.pw_dir)
        let trashPath = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path

        let standardized = URL(fileURLWithPath: item.path).standardizedFileURL
        // Lexical guard for a clear error; the pinned-fd unlinkat below is what
        // actually confines the removal to the real Trash.
        guard standardized.deletingLastPathComponent().standardizedFileURL.path == trashPath else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }

        let trashFd = SecureTrashFileOps.openTrashDirectory(home: home)
        guard trashFd >= 0 else { throw PrivilegedHelperError.symlinkRejected("\(home)/.Trash") }
        defer { close(trashFd) }

        let leaf = standardized.lastPathComponent
        var info = stat()
        guard fstatat(trashFd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PrivilegedHelperError.missingPath(item.path)
        }
        guard SecureTrashFileOps.removeTree(inDirFd: trashFd, name: leaf) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }
    }

    /// Move `url` into the invoking user's Trash so the removed item is visible
    /// and restorable in Finder.
    ///
    /// Both the source and the destination are resolved without following any
    /// symlink an unprivileged user could plant: the destination is a pinned
    /// `~/.Trash` descriptor (`O_NOFOLLOW` on `.Trash`), and the source parent is
    /// opened with an `O_NOFOLLOW` component walk of its real `/private` path, so
    /// a user who controls an intermediate component under a world-writable root
    /// can't swap it for a symlink to redirect the rename. The move is atomic and
    /// exclusive (`renameatx_np`/`RENAME_EXCL`).
    ///
    /// The moved item is **not** chowned to the user: transferring ownership of a
    /// moved inode is unsafe when it may be hard-linked to a root-owned file
    /// outside the Trash. It stays root-owned in the user's Trash. A missing
    /// invoking uid fails closed rather than moving to the root Trash.
    private func moveToTrash(_ url: URL, invokingUserID: UInt32?) throws -> URL {
        guard let uid = invokingUserID, let pw = getpwuid(uid) else {
            throw PrivilegedHelperError.rejectedPath(url.path)
        }
        let home = String(cString: pw.pointee.pw_dir)

        let trashFd = SecureTrashFileOps.openTrashDirectory(home: home)
        guard trashFd >= 0 else { throw PrivilegedHelperError.symlinkRejected("\(home)/.Trash") }
        defer { close(trashFd) }

        // The source parent is validated as an allowlisted system root, but open
        // it via an O_NOFOLLOW component walk of its real /private path so a
        // swapped intermediate component (under a world-writable root) can't
        // redirect the rename. renameatx_np then acts only on the leaf name.
        let parentPath = PrivilegedRemovabilityPolicy.firmlinkResolved(
            url.deletingLastPathComponent().path
        )
        let leaf = url.lastPathComponent
        let parentFd = SecureTrashFileOps.openDirectoryNoFollow(path: parentPath)
        guard parentFd >= 0 else { throw PrivilegedHelperError.missingPath(parentPath) }
        defer { close(parentFd) }

        guard let destName = SecureTrashFileOps.moveIntoTrash(
            sourceParentFd: parentFd,
            leaf: leaf,
            trashFd: trashFd
        ) else {
            // Same-volume by construction (Trash and system roots share the APFS
            // Data volume), so a move failure is a real error, not EXDEV.
            throw PrivilegedHelperError.rejectedPath(url.path)
        }

        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(destName)
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
        // cleanup target here, so refuse to move it at all. Defense in depth:
        // the move no longer transfers ownership, so a hard link alone can't
        // escalate, but rejecting a multiply-linked temp/cache file (a genuine
        // one has `st_nlink == 1`) keeps the helper from relocating a second
        // name for an unrelated root-owned file into the user's Trash. The
        // symlink guard above does not catch this: a hard link is not a symlink,
        // so `resolvingSymlinksInPath` leaves it unchanged.
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
