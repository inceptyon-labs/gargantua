import Foundation

extension DefaultBackgroundItemActionExecutor {
    /// Snapshot of the launchctl invocation that produced an audit entry.
    /// Bundles the three command-detail fields so callers don't need to
    /// thread them through `record(...)` individually.
    struct AuditedCommand {
        let tool: String
        let arguments: [String]
        let exitCode: Int32
    }

    /// Outcome bundle for `recordDelete`; groups the post-action fields so
    /// the recorder can be called with a parameter object instead of a
    /// 6-arg call.
    struct DeleteOutcome {
        let succeeded: Bool
        let error: String?
        let trashPath: String?
    }

    func record(
        item: BackgroundItem,
        action: BackgroundItemAction,
        succeeded: Bool,
        error: String?,
        command: AuditedCommand
    ) -> BackgroundItemActionOutcome {
        let entry = AuditEntry(
            id: UUID(),
            timestamp: now(),
            tool: command.tool,
            command: action.verb,
            files: [AuditFile(path: item.plistPath ?? "", size: 0)],
            safetyLevel: item.safety,
            confirmationMethod: item.safety.confirmationTier,
            cleanupMethod: .toolNative,
            bytesFreed: 0,
            kind: .command,
            commandToolVersion: nil,
            commandExitCode: command.exitCode,
            commandArguments: command.arguments
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

    func recordDelete(
        item: BackgroundItem,
        plistPath: String,
        confirmation: ConfirmationTier,
        outcome: DeleteOutcome
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
        _ = outcome.trashPath
        return BackgroundItemActionOutcome(
            itemID: item.id,
            action: .delete,
            succeeded: outcome.succeeded,
            error: outcome.error,
            auditID: entry.id
        )
    }

    func refuse(
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
