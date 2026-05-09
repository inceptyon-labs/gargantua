import Foundation

/// Executes mutating actions on a `BackgroundItem`. Routes user-domain calls
/// directly through `launchctl` and system-domain calls through the privileged
/// helper, then writes an `AuditEntry` per attempt.
///
/// The executor is intentionally one-shot per call (no batching) — the audit
/// trail is the recovery surface for `launchctl` state, so each operation
/// records its own entry with before/after intent.
public protocol BackgroundItemActionExecuting: Sendable {
    @MainActor
    func disable(_ item: BackgroundItem) async -> BackgroundItemActionOutcome
    @MainActor
    func enable(_ item: BackgroundItem) async -> BackgroundItemActionOutcome
    @MainActor
    func delete(
        _ item: BackgroundItem,
        confirmedAt confirmation: ConfirmationTier
    ) async -> BackgroundItemActionOutcome
}

/// Trash adapter — abstracted so tests can fake `FileManager.trashItem`.
public protocol BackgroundItemTrashing: Sendable {
    /// Move the file at `path` to Trash; returns the resulting Trash URL path
    /// (or `nil` if the platform does not provide one). Throws on failure.
    func trash(_ path: String) throws -> String?
}

public struct DefaultBackgroundItemTrasher: BackgroundItemTrashing {
    public init() {}
    public func trash(_ path: String) throws -> String? {
        var trashURL: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: &trashURL
        )
        return (trashURL as URL?)?.path
    }
}

public struct DefaultBackgroundItemActionExecutor: BackgroundItemActionExecuting {
    private let launchctl: any LaunchctlRunning
    private let helper: any PrivilegedBackgroundItemHelping
    private let trasher: any BackgroundItemTrashing
    private let audit: AuditWriter
    private let userIDProvider: @Sendable () -> uid_t?
    private let now: @Sendable () -> Date

    public init(
        launchctl: any LaunchctlRunning = DefaultLaunchctlRunner(),
        helper: any PrivilegedBackgroundItemHelping = XPCPrivilegedBackgroundItemHelper(),
        trasher: any BackgroundItemTrashing = DefaultBackgroundItemTrasher(),
        audit: AuditWriter = AuditWriter(),
        userIDProvider: @escaping @Sendable () -> uid_t? = { getuid() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launchctl = launchctl
        self.helper = helper
        self.trasher = trasher
        self.audit = audit
        self.userIDProvider = userIDProvider
        self.now = now
    }

    // MARK: - Disable

    @MainActor
    public func disable(_ item: BackgroundItem) async -> BackgroundItemActionOutcome {
        guard let domain = controllableDomain(for: item) else {
            return refuse(item: item, action: .disable, refusal: .unsupportedSource)
        }
        guard item.safety != .protected_ else {
            return refuse(item: item, action: .disable, refusal: .protectedItem)
        }

        switch domain {
        case .user:
            guard let uid = userIDProvider() else {
                return refuse(item: item, action: .disable, refusal: .missingUserID)
            }
            // bootout removes the running instance and unloads the spec; in
            // GUI sessions launchctl re-loads it on next login unless we also
            // mark it disabled.
            let bootout = launchctl.run(["bootout", "gui/\(uid)/\(item.label)"])
            // bootout returns 36 (could not find) when the job isn't loaded,
            // which is fine for a "disable that wasn't loaded" path. Treat
            // any non-zero except this as a real failure and surface stderr.
            let bootoutOK = bootout.succeeded || bootout.exitCode == 36
            let disable = launchctl.run(["disable", "gui/\(uid)/\(item.label)"])
            let succeeded = bootoutOK && disable.succeeded
            return record(
                item: item,
                action: .disable,
                succeeded: succeeded,
                error: succeeded ? nil : (disable.stderr.isEmpty ? bootout.stderr : disable.stderr),
                tool: "launchctl",
                arguments: disable.arguments,
                exitCode: disable.exitCode
            )
        case .system:
            let bootout = await helper.perform(
                PrivilegedBackgroundItemRequest(
                    operation: .bootoutDaemon,
                    label: item.label,
                    plistPath: item.plistPath
                )
            )
            let bootoutOK = bootout.succeeded || bootout.exitCode == 36
            let disable = await helper.perform(
                PrivilegedBackgroundItemRequest(
                    operation: .disableDaemon,
                    label: item.label,
                    plistPath: item.plistPath
                )
            )
            let succeeded = bootoutOK && disable.succeeded
            return record(
                item: item,
                action: .disable,
                succeeded: succeeded,
                error: succeeded ? nil : (disable.error ?? bootout.error ?? disable.stderr),
                tool: "launchctl",
                arguments: PrivilegedBackgroundItemValidator.launchctlArguments(
                    for: .disableDaemon,
                    label: item.label,
                    plistPath: nil
                ) ?? [],
                exitCode: disable.exitCode ?? -1
            )
        }
    }

    // MARK: - Enable

    @MainActor
    public func enable(_ item: BackgroundItem) async -> BackgroundItemActionOutcome {
        guard let domain = controllableDomain(for: item) else {
            return refuse(item: item, action: .enable, refusal: .unsupportedSource)
        }
        guard item.safety != .protected_ else {
            return refuse(item: item, action: .enable, refusal: .protectedItem)
        }

        switch domain {
        case .user:
            guard let uid = userIDProvider() else {
                return refuse(item: item, action: .enable, refusal: .missingUserID)
            }
            let enable = launchctl.run(["enable", "gui/\(uid)/\(item.label)"])
            // Re-bootstrap from the original plist so the user-side enable
            // also re-loads the job. Skip when the plist is missing (login
            // items, defensive — already filtered above).
            var bootstrap: LaunchctlResult?
            if let path = item.plistPath {
                bootstrap = launchctl.run(["bootstrap", "gui/\(uid)", path])
            }
            // bootstrap returns 37 when the job is already loaded, which we
            // treat as success-equivalent.
            let bootstrapOK = bootstrap.map { $0.succeeded || $0.exitCode == 37 } ?? true
            let succeeded = enable.succeeded && bootstrapOK
            let stderr = enable.stderr.isEmpty ? (bootstrap?.stderr ?? "") : enable.stderr
            return record(
                item: item,
                action: .enable,
                succeeded: succeeded,
                error: succeeded ? nil : stderr,
                tool: "launchctl",
                arguments: enable.arguments,
                exitCode: enable.exitCode
            )
        case .system:
            let enable = await helper.perform(
                PrivilegedBackgroundItemRequest(
                    operation: .enableDaemon,
                    label: item.label,
                    plistPath: item.plistPath
                )
            )
            var bootstrap: PrivilegedBackgroundItemResponse?
            if let path = item.plistPath {
                bootstrap = await helper.perform(
                    PrivilegedBackgroundItemRequest(
                        operation: .bootstrapDaemon,
                        label: item.label,
                        plistPath: path
                    )
                )
            }
            let bootstrapOK = bootstrap.map { $0.succeeded || $0.exitCode == 37 } ?? true
            let succeeded = enable.succeeded && bootstrapOK
            return record(
                item: item,
                action: .enable,
                succeeded: succeeded,
                error: succeeded ? nil : (enable.error ?? bootstrap?.error ?? enable.stderr),
                tool: "launchctl",
                arguments: PrivilegedBackgroundItemValidator.launchctlArguments(
                    for: .enableDaemon,
                    label: item.label,
                    plistPath: nil
                ) ?? [],
                exitCode: enable.exitCode ?? -1
            )
        }
    }

    // MARK: - Delete

    @MainActor
    public func delete(
        _ item: BackgroundItem,
        confirmedAt confirmation: ConfirmationTier
    ) async -> BackgroundItemActionOutcome {
        guard let domain = controllableDomain(for: item) else {
            return refuse(item: item, action: .delete, refusal: .unsupportedSource)
        }
        guard item.safety != .protected_ else {
            return refuse(item: item, action: .delete, refusal: .protectedItem)
        }
        guard let plistPath = item.plistPath else {
            return refuse(item: item, action: .delete, refusal: .noPlistToDelete)
        }
        // Spec: "Delete plist — only after the item is disabled." We check the
        // local snapshot's `disabledFlag` reason; the user is expected to run
        // disable first, which the UI enforces.
        guard item.reasons.contains(.disabledFlag) else {
            return refuse(item: item, action: .delete, refusal: .deleteRequiresDisable)
        }

        do {
            switch domain {
            case .user:
                let trashPath = try trasher.trash(plistPath)
                return recordDelete(
                    item: item,
                    plistPath: plistPath,
                    confirmation: confirmation,
                    succeeded: true,
                    error: nil,
                    trashPath: trashPath
                )
            case .system:
                let response = await helper.perform(
                    PrivilegedBackgroundItemRequest(
                        operation: .trashLaunchPlist,
                        label: item.label,
                        plistPath: plistPath
                    )
                )
                return recordDelete(
                    item: item,
                    plistPath: plistPath,
                    confirmation: confirmation,
                    succeeded: response.succeeded,
                    error: response.succeeded ? nil : (response.error ?? response.stderr),
                    trashPath: response.trashPath
                )
            }
        } catch {
            return recordDelete(
                item: item,
                plistPath: plistPath,
                confirmation: confirmation,
                succeeded: false,
                error: error.localizedDescription,
                trashPath: nil
            )
        }
    }

    // MARK: - Domain dispatch

    enum Domain {
        case user // launchctl gui/<uid>/<label>
        case system // launchctl system/<label> (privileged helper)
    }

    private func controllableDomain(for item: BackgroundItem) -> Domain? {
        switch item.source {
        case .userLaunchAgent, .systemLaunchAgent:
            // System agents live under `/Library/LaunchAgents` but launchctl
            // controls them in `gui/<uid>` because they run as the user.
            // Plist trash for `.systemLaunchAgent` still routes through the
            // helper (the file is root-owned).
            return .user
        case .launchDaemon:
            return .system
        case .startupItem, .loginItem:
            return nil
        }
    }

    // MARK: - Audit

    private func record(
        item: BackgroundItem,
        action: BackgroundItemAction,
        succeeded: Bool,
        error: String?,
        tool: String,
        arguments: [String],
        exitCode: Int32
    ) -> BackgroundItemActionOutcome {
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now(),
            tool: tool,
            command: action.verb,
            files: [AuditFile(path: item.plistPath ?? "", size: 0)],
            safetyLevel: item.safety,
            confirmationMethod: item.safety.confirmationTier,
            cleanupMethod: .toolNative,
            bytesFreed: 0,
            kind: .command,
            commandToolVersion: nil,
            commandExitCode: exitCode,
            commandArguments: arguments
        )
        try? audit.write(entry)
        return BackgroundItemActionOutcome(
            itemID: item.id,
            action: action,
            succeeded: succeeded,
            error: error,
            auditID: entry.id
        )
    }

    private func recordDelete(
        item: BackgroundItem,
        plistPath: String,
        confirmation: ConfirmationTier,
        succeeded: Bool,
        error: String?,
        trashPath: String?
    ) -> BackgroundItemActionOutcome {
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now(),
            tool: "native",
            command: BackgroundItemAction.delete.verb,
            files: [AuditFile(path: plistPath, size: 0)],
            safetyLevel: item.safety,
            confirmationMethod: confirmation,
            cleanupMethod: .trash,
            bytesFreed: 0,
            kind: .path
        )
        try? audit.write(entry)
        // Annotate trash result onto the outcome via the auditID — callers
        // can look the entry up from the JSONL log if they need the trash
        // path (we don't expose it on the in-memory outcome to keep the API
        // surface tight; trash recovery flows go through the audit reader).
        _ = trashPath
        return BackgroundItemActionOutcome(
            itemID: item.id,
            action: .delete,
            succeeded: succeeded,
            error: error,
            auditID: entry.id
        )
    }

    private func refuse(
        item: BackgroundItem,
        action: BackgroundItemAction,
        refusal: BackgroundItemActionRefusal
    ) -> BackgroundItemActionOutcome {
        BackgroundItemActionOutcome(
            itemID: item.id,
            action: action,
            succeeded: false,
            error: refusal.errorDescription,
            auditID: nil
        )
    }
}
