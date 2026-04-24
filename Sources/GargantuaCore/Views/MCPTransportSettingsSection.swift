import SwiftUI

struct MCPTransportSettingsSection: View {
    @State private var configuration = MCPSSEServerConfiguration()
    @State private var tokenStatus = "Token not generated"
    @State private var generatedToken: String?
    @State private var hasBearerToken = false

    private let configurationStore = MCPSSEConfigurationStore()
    private let tokenManager = MCPBearerTokenManager()

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            Text("MCP Transport")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                statusHeader

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
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
        .task {
            configuration = configurationStore.load()
            refreshTokenStatus()
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: configuration.isEnabled ? "dot.radiowaves.left.and.right" : "terminal")
                .font(.system(size: 18))
                .foregroundStyle(statusColor)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Server-Sent Events")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text("\(configuration.bindHost):\(configuration.port)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { configuration.isEnabled },
                set: {
                    configuration.isEnabled = $0
                    saveConfiguration()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var bindRow: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
            Image(systemName: "network")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bind")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Text(configuration.bindScope.detail)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

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
                Image(systemName: "number")
                    .font(.system(size: 14))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 20, alignment: .center)

                Text("Port")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Text("\(configuration.port)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
    }

    private var tokenRow: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "key")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 20, alignment: .center)

            Text("Bearer Token")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            transportActionButton(
                label: "Generate",
                icon: "plus.circle.fill",
                color: GargantuaColors.safe,
                action: generateToken
            )

            transportActionButton(
                label: "Rotate",
                icon: "arrow.triangle.2.circlepath",
                color: GargantuaColors.accent,
                action: rotateToken
            )

            transportActionButton(
                label: "Revoke",
                icon: "trash",
                color: GargantuaColors.protected_,
                action: revokeToken
            )
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

    private func transportActionButton(
        label: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(GargantuaFonts.label)
            }
            .foregroundStyle(color)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
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
