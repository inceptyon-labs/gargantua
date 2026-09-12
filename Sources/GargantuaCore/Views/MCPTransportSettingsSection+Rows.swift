import SwiftUI

extension MCPTransportSettingsSection {
    var statusHeader: some View {
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

    var runtimeRow: some View {
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

    var runtimeStatusLine: String {
        let snapshot = serverModel.snapshot
        if snapshot.isRunning {
            let count = snapshot.clients.count
            return count == 0 ? "Running, no clients connected" : "Running, \(count) connected"
        }
        if let message = snapshot.lastErrorMessage { return message }
        return "Stopped"
    }

    var bindRow: some View {
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

    var portRow: some View {
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

    var tokenRow: some View {
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

    func tokenDisplay(_ token: String) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Text(token)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            GargantuaIconButton(
                icon: "doc.on.doc",
                help: "Copy token to clipboard",
                color: GargantuaColors.accent,
                action: { copyToClipboard(token) }
            )
        }
        .padding(GargantuaSpacing.space3)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    var tokenStatusIcon: String {
        switch tokenStatusTone {
        case .safe: return "checkmark.circle.fill"
        case .protected: return "xmark.octagon.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    var tokenStatusTone: SettingsNoticeRow.Tone {
        if tokenStatus.contains("locked out")
            || tokenStatus.contains("error")
            || tokenStatus.contains("failed") {
            return .protected
        }
        if tokenStatus.contains("LAN binding needs") {
            return .review
        }
        if tokenStatus.contains("Keychain")
            || tokenStatus.contains("rotated")
            || tokenStatus.contains("clipboard") {
            return .safe
        }
        return .info
    }

    var statusColor: Color {
        if configuration.requiresBearerToken {
            return hasBearerToken ? GargantuaColors.safe : GargantuaColors.review
        }
        return configuration.isEnabled ? GargantuaColors.safe : GargantuaColors.ink4
    }
}
