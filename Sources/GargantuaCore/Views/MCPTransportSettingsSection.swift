import SwiftUI

struct MCPTransportSettingsSection: View {
    @State private var configuration = MCPSSEServerConfiguration()
    @State private var tokenStatus = "Token not generated"
    @State private var generatedToken: String?
    @State private var hasBearerToken = false
    @State private var pendingDestructive: DestructiveAction?
    @StateObject private var serverModel = MCPServerStatusViewModel()

    private let configurationStore = MCPSSEConfigurationStore()
    private let tokenManager = MCPBearerTokenManager()

    private enum DestructiveAction: Identifiable {
        case rotate, revoke
        var id: String {
            switch self {
            case .rotate: "rotate"
            case .revoke: "revoke"
            }
        }

        var sheetTitle: String {
            switch self {
            case .rotate: "Rotate bearer token?"
            case .revoke: "Revoke bearer token?"
            }
        }

        var sheetMessage: String {
            switch self {
            case .rotate:
                "The current token stops working immediately and a new one replaces it in Keychain. Any MCP client using the old token will lose access."
            case .revoke:
                "The token is deleted from Keychain. MCP clients will be locked out until a new token is generated. This cannot be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .rotate: "Rotate token"
            case .revoke: "Revoke token"
            }
        }
    }

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

            Text(tokenStatus)
                .font(GargantuaFonts.caption)
                .foregroundStyle(statusColor)
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

    private var runtimeRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "play.circle", size: 14)

            SettingsRowText(title: "Server", detail: runtimeStatusLine)

            Spacer()

            if serverModel.snapshot.isRunning {
                GargantuaButton(
                    "Stop",
                    icon: "stop.fill",
                    tone: .ghost(GargantuaColors.protected_),
                    action: { serverModel.stop() }
                )
                .help("Stop the MCP server")
            } else {
                GargantuaButton(
                    "Start",
                    icon: "play.fill",
                    tone: .ghost(GargantuaColors.accent),
                    action: { serverModel.start() }
                )
                .help("Start the MCP server")
            }
        }
    }

    private var runtimeStatusLine: String {
        let snapshot = serverModel.snapshot
        if snapshot.isRunning {
            let count = snapshot.clients.count
            return count == 0 ? "Running, no clients connected" : "Running, \(count) connected"
        }
        if let message = snapshot.lastErrorMessage { return message }
        return "Stopped"
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(
                systemName: configuration.isEnabled ? "dot.radiowaves.left.and.right" : "terminal",
                color: statusColor,
                size: 18
            )

            SettingsRowText(
                title: "Server-Sent Events",
                detail: "\(configuration.bindHost):\(configuration.port)"
            )

            Spacer()

            Toggle("Enable MCP transport", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .help(configuration.isEnabled ? "Disable MCP transport" : "Enable MCP transport")
        }
    }

    private var bindRow: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "network", size: 14)

            SettingsRowText(title: "Bind", detail: configuration.bindScope.detail)

            Spacer(minLength: GargantuaSpacing.space3)

            Picker("Bind", selection: bindScopeBinding) {
                ForEach(MCPServerBindScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private var portRow: some View {
        Stepper(value: portBinding, in: MCPSSEServerConfiguration.validPortRange, step: 1) {
            HStack(spacing: GargantuaSpacing.space3) {
                SettingsRowIcon(systemName: "number", size: 14)

                Text("Port")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Text("\(configuration.port)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .help("Local port the MCP server binds to")
    }

    private var tokenRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "key", size: 14)

            Text("Bearer token")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            GargantuaButton(
                "Generate",
                icon: "plus.circle.fill",
                tone: .ghost(GargantuaColors.safe),
                action: generateToken
            )
            .help("Create a token and store it in Keychain")

            GargantuaButton(
                "Rotate",
                icon: "arrow.triangle.2.circlepath",
                tone: .ghost(GargantuaColors.accent),
                isDisabled: !hasBearerToken,
                action: { pendingDestructive = .rotate }
            )
            .help("Replace the current token with a new one")

            GargantuaButton(
                "Revoke",
                icon: "trash",
                tone: .ghost(GargantuaColors.protected_),
                isDisabled: !hasBearerToken,
                action: { pendingDestructive = .revoke }
            )
            .help("Delete the stored bearer token")
        }
    }

    private func tokenDisplay(_ token: String) -> some View {
        Text(token)
            .font(GargantuaFonts.monoPath)
            .foregroundStyle(GargantuaColors.ink)
            .lineLimit(2)
            .textSelection(.enabled)
            .padding(GargantuaSpacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private var bindScopeBinding: Binding<MCPServerBindScope> {
        Binding(
            get: { configuration.bindScope },
            set: {
                configuration.bindScope = $0
                saveConfiguration()
                refreshTokenStatus()
            }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { configuration.port },
            set: {
                configuration.port = MCPSSEServerConfiguration.normalizedPort($0)
                saveConfiguration()
            }
        )
    }

    private func saveConfiguration() {
        configurationStore.save(configuration)
    }

    private func generateToken() {
        do {
            guard !(try tokenManager.hasToken()) else {
                hasBearerToken = true
                tokenStatus = "Token already stored in Keychain"
                generatedToken = nil
                return
            }
            generatedToken = try tokenManager.rotateToken()
            hasBearerToken = true
            tokenStatus = "Token generated and stored in Keychain"
        } catch {
            tokenStatus = error.localizedDescription
            generatedToken = nil
        }
    }

    private func rotateToken() {
        do {
            generatedToken = try tokenManager.rotateToken()
            hasBearerToken = true
            tokenStatus = "Token rotated and stored in Keychain"
        } catch {
            tokenStatus = error.localizedDescription
            generatedToken = nil
        }
    }

    private func revokeToken() {
        do {
            try tokenManager.revokeToken()
            generatedToken = nil
            hasBearerToken = false
            tokenStatus = "Token revoked"
        } catch {
            tokenStatus = error.localizedDescription
        }
    }

    private func refreshTokenStatus() {
        do {
            hasBearerToken = try tokenManager.hasToken()
            if hasBearerToken {
                tokenStatus = "Token stored in Keychain"
            } else if configuration.requiresBearerToken {
                tokenStatus = "LAN binding needs a bearer token"
            } else {
                tokenStatus = "Token not generated"
            }
        } catch {
            tokenStatus = error.localizedDescription
        }
    }

    private var statusColor: Color {
        if configuration.requiresBearerToken {
            return hasBearerToken ? GargantuaColors.safe : GargantuaColors.review
        }
        return configuration.isEnabled ? GargantuaColors.safe : GargantuaColors.ink4
    }
}
