import SwiftUI

enum SidebarServiceIndicatorTone: Equatable {
    case active
    case attention
    case inactive
}

struct SidebarServiceIndicatorPresentation: Equatable {
    let label: String
    let status: String
    let detail: String
    let tone: SidebarServiceIndicatorTone

    static let native = SidebarServiceIndicatorPresentation(
        label: "Native",
        status: "Ready",
        detail: "Native scanner is available.",
        tone: .active
    )

    static func mcp(from snapshot: MCPServerStatusSnapshot) -> SidebarServiceIndicatorPresentation {
        switch snapshot.state {
        case .running:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: snapshot.transportMode.displayName,
                detail: "MCP server running over \(snapshot.transportMode.displayName).",
                tone: .active
            )
        case .starting:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: "Starting",
                detail: "MCP server is starting.",
                tone: .attention
            )
        case .error:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: "Error",
                detail: snapshot.lastErrorMessage ?? "MCP server reported an error.",
                tone: .attention
            )
        case .stopped:
            SidebarServiceIndicatorPresentation(
                label: "MCP",
                status: "Off",
                detail: "MCP server is not running.",
                tone: .inactive
            )
        }
    }

    static func tier3(
        configuration: ClaudeCodeAgentConfiguration,
        cliAvailable: Bool
    ) -> SidebarServiceIndicatorPresentation {
        guard configuration.isEnabled else {
            return SidebarServiceIndicatorPresentation(
                label: "Tier 3",
                status: "Off",
                detail: "Tier 3 Claude Code Agent is disabled.",
                tone: .inactive
            )
        }

        if cliAvailable {
            return SidebarServiceIndicatorPresentation(
                label: "Tier 3",
                status: "Ready",
                detail: "Tier 3 Claude Code Agent is enabled.",
                tone: .active
            )
        }

        return SidebarServiceIndicatorPresentation(
            label: "Tier 3",
            status: "Needs CLI",
            detail: "Tier 3 is enabled, but the Claude Code CLI is not available.",
            tone: .attention
        )
    }
}

/// Compact footer showing hardware model, macOS version, disk usage, engine status, MCP, and Tier 3.
struct SystemInfoBar: View {
    @ObservedObject var mcpStatusModel: MCPServerStatusViewModel

    @State private var hardwareModel: String?
    @State private var diskTotalGB: Int?
    @State private var diskUsedGB: Int?
    @State private var tier3Presentation = SidebarServiceIndicatorPresentation.tier3(
        configuration: ClaudeCodeAgentConfiguration(),
        cliAvailable: false
    )

    private let agentConfigurationStore = ClaudeCodeAgentConfigurationStore()
    private let agentCLIResolver = ClaudeCodeCLIResolver()

    private var mcpPresentation: SidebarServiceIndicatorPresentation {
        SidebarServiceIndicatorPresentation.mcp(from: mcpStatusModel.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            // Line 1: Hardware model · macOS version
            Text(hardwareLine)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)

            // Line 2: Disk usage
            Text(diskLine)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)
                .lineLimit(1)

            // Line 3: Runtime integrations
            HStack(spacing: GargantuaSpacing.space2) {
                statusIndicator(.native)

                Spacer().frame(width: GargantuaSpacing.space1)

                statusIndicator(mcpPresentation)

                Spacer().frame(width: GargantuaSpacing.space1)

                statusIndicator(tier3Presentation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, GargantuaSpacing.space2)
        .padding(.horizontal, GargantuaSpacing.space3)
        .onAppear {
            refreshSystemInfo()
            refreshRuntimeStatus()
        }
        .task {
            await refreshRuntimeStatusLoop()
        }
    }

    private var hardwareLine: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "macOS \(version.majorVersion).\(version.minorVersion)"
        if let model = hardwareModel {
            return "\(model) · \(macOS)"
        }
        return macOS
    }

    private var diskLine: String {
        if let used = diskUsedGB, let total = diskTotalGB {
            return "\(used) / \(total) GB used"
        }
        return "Disk info unavailable"
    }

    @ViewBuilder
    private func statusIndicator(_ presentation: SidebarServiceIndicatorPresentation) -> some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Circle()
                .fill(color(for: presentation.tone))
                .frame(width: 6, height: 6)

            Text(presentation.label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(textColor(for: presentation.tone))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .help("\(presentation.label): \(presentation.status). \(presentation.detail)")
        .accessibilityLabel("\(presentation.label) \(presentation.status)")
    }

    private func refreshSystemInfo() {
        hardwareModel = Self.queryHardwareModel()
        refreshDisk()
    }

    private func refreshRuntimeStatus() {
        mcpStatusModel.refresh()
        let configuration = agentConfigurationStore.load()
        tier3Presentation = SidebarServiceIndicatorPresentation.tier3(
            configuration: configuration,
            cliAvailable: (try? agentCLIResolver.resolve(configuration: configuration)) != nil
        )
    }

    @MainActor
    private func refreshRuntimeStatusLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshRuntimeStatus()
        }
    }

    private func refreshDisk() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ) {
            if let totalBytes = attrs[.systemSize] as? UInt64 {
                diskTotalGB = Int(totalBytes / (1024 * 1024 * 1024))
            }
            if let freeBytes = attrs[.systemFreeSize] as? UInt64,
               let totalBytes = attrs[.systemSize] as? UInt64 {
                diskUsedGB = Int((totalBytes - freeBytes) / (1024 * 1024 * 1024))
            }
        }
    }

    private static func queryHardwareModel() -> String? {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let raw = String(cString: model)
        return Self.friendlyModelName(raw)
    }

    private static func friendlyModelName(_ raw: String) -> String {
        if raw.contains("MacBookPro") { return "MacBook Pro" }
        if raw.contains("MacBookAir") { return "MacBook Air" }
        if raw.contains("Macmini") { return "Mac mini" }
        if raw.contains("MacPro") { return "Mac Pro" }
        if raw.contains("iMac") { return "iMac" }
        if raw.contains("Mac") { return "Mac" }
        return raw
    }

    private func color(for tone: SidebarServiceIndicatorTone) -> Color {
        switch tone {
        case .active: GargantuaColors.safe
        case .attention: GargantuaColors.review
        case .inactive: GargantuaColors.ink4
        }
    }

    private func textColor(for tone: SidebarServiceIndicatorTone) -> Color {
        switch tone {
        case .active, .attention: GargantuaColors.ink3
        case .inactive: GargantuaColors.ink4
        }
    }
}
