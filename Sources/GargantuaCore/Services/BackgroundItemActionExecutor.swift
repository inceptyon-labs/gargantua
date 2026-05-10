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
    let audit: AuditWriter
    private let userIDProvider: @Sendable () -> uid_t?
    let now: @Sendable () -> Date

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
            // The audit must reflect the step that *actually* dictated the
            // outcome. When bootout fails we surface its args/exit; when
            // bootout was acceptable but disable failed, we surface disable.
            let primary = bootoutOK ? disable : bootout
            return record(
                item: item,
                action: .disable,
                succeeded: succeeded,
                error: succeeded ? nil : (primary.stderr.isEmpty ? "launchctl exited \(primary.exitCode)" : primary.stderr),
                command: AuditedCommand(
                    tool: "launchctl",
                    arguments: primary.arguments,
                    exitCode: primary.exitCode
                )
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
            let disable = bootoutOK ? await helper.perform(
                PrivilegedBackgroundItemRequest(
                    operation: .disableDaemon,
                    label: item.label,
                    plistPath: item.plistPath
                )
            ) : nil
            let succeeded = bootoutOK && (disable?.succeeded ?? false)
            // Audit the step whose outcome decided the overall outcome:
            // either the failed bootout, or (if bootout was OK) the disable.
            let primaryOp: PrivilegedBackgroundItemOperation = bootoutOK ? .disableDaemon : .bootoutDaemon
            let primary = bootoutOK ? disable : bootout
            return record(
                item: item,
                action: .disable,
                succeeded: succeeded,
                error: succeeded ? nil : (primary?.error ?? primary?.stderr ?? "launchctl rejected"),
                command: AuditedCommand(
                    tool: "launchctl",
                    arguments: PrivilegedBackgroundItemValidator.launchctlArguments(
                        for: primaryOp,
                        label: item.label,
                        plistPath: item.plistPath
                    ) ?? [],
                    exitCode: primary?.exitCode ?? -1
                )
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
            // items, defensive — already filtered above). Bootstrap is only
            // attempted after enable succeeded so a failure point pins to
            // the right subcommand in the audit.
            var bootstrap: LaunchctlResult?
            if enable.succeeded, let path = item.plistPath {
                bootstrap = launchctl.run(["bootstrap", "gui/\(uid)", path])
            }
            // bootstrap returns 37 when the job is already loaded, which we
            // treat as success-equivalent.
            let bootstrapOK = bootstrap.map { $0.succeeded || $0.exitCode == 37 } ?? true
            let succeeded = enable.succeeded && bootstrapOK
            let primary: LaunchctlResult = !enable.succeeded ? enable : (bootstrap ?? enable)
            return record(
                item: item,
                action: .enable,
                succeeded: succeeded,
                error: succeeded ? nil : (primary.stderr.isEmpty ? "launchctl exited \(primary.exitCode)" : primary.stderr),
                command: AuditedCommand(
                    tool: "launchctl",
                    arguments: primary.arguments,
                    exitCode: primary.exitCode
                )
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
            if enable.succeeded, let path = item.plistPath {
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
            let primaryOp: PrivilegedBackgroundItemOperation = enable.succeeded ? .bootstrapDaemon : .enableDaemon
            let primary: PrivilegedBackgroundItemResponse = !enable.succeeded ? enable : (bootstrap ?? enable)
            return record(
                item: item,
                action: .enable,
                succeeded: succeeded,
                error: succeeded ? nil : (primary.error ?? primary.stderr ?? "launchctl rejected"),
                command: AuditedCommand(
                    tool: "launchctl",
                    arguments: PrivilegedBackgroundItemValidator.launchctlArguments(
                        for: primaryOp,
                        label: item.label,
                        plistPath: item.plistPath
                    ) ?? [],
                    exitCode: primary.exitCode ?? -1
                )
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

        // Trash routing depends on the plist *location*, not the launchctl
        // domain. System launch agents are controlled in `gui/<uid>` (user
        // domain) but their plists live in root-owned `/Library/LaunchAgents/`,
        // so the trash op still has to go through the privileged helper.
        _ = domain
        do {
            if requiresPrivilegedTrash(plistPath: plistPath) {
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
                    outcome: DeleteOutcome(
                        succeeded: response.succeeded,
                        error: response.succeeded ? nil : (response.error ?? response.stderr),
                        trashPath: response.trashPath
                    )
                )
            } else {
                let trashPath = try trasher.trash(plistPath)
                return recordDelete(
                    item: item,
                    plistPath: plistPath,
                    confirmation: confirmation,
                    outcome: DeleteOutcome(succeeded: true, error: nil, trashPath: trashPath)
                )
            }
        } catch {
            return recordDelete(
                item: item,
                plistPath: plistPath,
                confirmation: confirmation,
                outcome: DeleteOutcome(succeeded: false, error: error.localizedDescription, trashPath: nil)
            )
        }
    }

    /// Plist paths under root-owned launchd directories must go through the
    /// privileged helper. The only sub-tree the user can trash directly is
    /// the per-user `~/Library/LaunchAgents/`.
    private func requiresPrivilegedTrash(plistPath: String) -> Bool {
        plistPath.hasPrefix("/Library/LaunchAgents/")
            || plistPath.hasPrefix("/Library/LaunchDaemons/")
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
}
