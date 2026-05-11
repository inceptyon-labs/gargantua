import AppKit
import SwiftUI

struct MCPTransportSettingsSection: View {
    @State var configuration = MCPSSEServerConfiguration()
    @State var tokenStatus = "Token not generated"
    @State var generatedToken: String?
    @State var hasBearerToken = false
    @State var pendingDestructive: DestructiveAction?
    @StateObject var serverModel = MCPServerStatusViewModel()

    let configurationStore = MCPSSEConfigurationStore()
    let tokenManager = MCPBearerTokenManager()

    var body: some View {
        SettingsSectionContainer(
            "MCP Transport",
            subtitle: "Local Server-Sent Events endpoint exposing read-only Gargantua tools to MCP clients."
        ) {
            statusHeader

            Divider()
                .overlay(GargantuaColors.border)

            runtimeRow

            Divider()
                .overlay(GargantuaColors.border)

            bindRow
            portRow

            Divider()
                .overlay(GargantuaColors.border)

            tokenRow

            if let generatedToken {
                tokenDisplay(generatedToken)
            }

            if !tokenStatus.isEmpty {
                SettingsNoticeRow(
                    icon: tokenStatusIcon,
                    message: tokenStatus,
                    tone: tokenStatusTone
                )
            }
        }
        .task {
            configuration = configurationStore.load()
            refreshTokenStatus()
            serverModel.refresh()
        }
        .sheet(item: $pendingDestructive) { action in
            DestructiveConfirmSheet(
                title: action.sheetTitle,
                message: action.sheetMessage,
                confirmLabel: action.confirmLabel,
                onCancel: { pendingDestructive = nil },
                onConfirm: {
                    pendingDestructive = nil
                    switch action {
                    case .rotate: rotateToken()
                    case .revoke: revokeToken()
                    }
                }
            )
        }
    }
}
