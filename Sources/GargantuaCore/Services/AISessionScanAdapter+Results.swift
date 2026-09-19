import Foundation

/// How `AISessionScanAdapter` renders each finding for the scan list.
///
/// Split out so the adapter file stays within the project's type-body limit;
/// these are pure functions of a finding and touch no adapter state.
extension AISessionScanAdapter {
    // MARK: - Result mapping

    static func makeScanResult(_ finding: AISessionFinding) -> ScanResult {
        switch finding.reason {
        case let .projectMissing(projectPath):
            return orphanResult(finding, projectPath: projectPath)
        case let .inactive(days):
            return inactiveScratchpadResult(finding, days: days)
        }
    }

    static func orphanResult(_ finding: AISessionFinding, projectPath: String) -> ScanResult {
        let what: String
        switch finding.kind {
        case .claudeCodeProject:
            what = "Conversation transcripts \(finding.toolName) kept for \(projectPath)."
        case .editorWorkspaceStorage:
            what = "Per-workspace editor and AI assistant state \(finding.toolName) kept for \(projectPath)."
        case .agentScratchpad:
            what = "Scratch files \(finding.toolName) kept for \(projectPath)."
        }

        return ScanResult(
            id: resultIDPrefix + sanitizedID(finding.path),
            name: "\(finding.toolName) session store — \(URL(fileURLWithPath: projectPath).lastPathComponent)",
            path: finding.path,
            size: finding.size,
            safety: .review,
            confidence: 76,
            explanation: [
                what,
                "That project folder no longer exists on disk, so nothing will reopen this store.",
                "It still holds your own conversation history, and a missing folder can mean a move rather than a",
                "deletion, so Gargantua marks this review and keeps removal behind confirmation.",
            ].joined(separator: " "),
            source: SourceAttribution(name: finding.toolName),
            lastAccessed: finding.lastActivity,
            category: category,
            tags: ["ai_history", "developer", tag, "review"].sorted(),
            regenerates: false
        )
    }

    static func inactiveScratchpadResult(_ finding: AISessionFinding, days: Int) -> ScanResult {
        let session = URL(fileURLWithPath: finding.path)
        let project = session.deletingLastPathComponent().lastPathComponent

        return ScanResult(
            id: resultIDPrefix + sanitizedID(finding.path),
            name: "\(finding.toolName) scratchpad — \(project)",
            path: finding.path,
            size: finding.size,
            safety: .review,
            confidence: 74,
            explanation: [
                "Working directory one \(finding.toolName) session was given for scratch files.",
                "Nothing anywhere inside it has been written for \(days) day\(days == 1 ? "" : "s"),",
                "measured against its newest file rather than the folder's own timestamp.",
                "Scratch space is temporary by design, but a session can leave a build, an export, or a report here,",
                "so Gargantua marks this review and keeps removal behind confirmation.",
            ].joined(separator: " "),
            source: SourceAttribution(name: finding.toolName),
            lastAccessed: finding.lastActivity,
            category: category,
            tags: ["ai_history", "developer", tag, "review", "temp"].sorted(),
            regenerates: false
        )
    }

    static func sanitizedID(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
            .lowercased()
    }
}
