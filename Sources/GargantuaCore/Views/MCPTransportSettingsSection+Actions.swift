import AppKit
import SwiftUI

extension MCPTransportSettingsSection {
    var bindScopeBinding: Binding<MCPServerBindScope> {
        Binding(
            get: { configuration.bindScope },
            set: {
                configuration.bindScope = $0
                saveConfiguration()
                refreshTokenStatus()
            }
        )
    }

    var portBinding: Binding<Int> {
        Binding(
            get: { configuration.port },
            set: {
                configuration.port = MCPSSEServerConfiguration.normalizedPort($0)
                saveConfiguration()
            }
        )
    }

    func saveConfiguration() {
        configurationStore.save(configuration)
    }

    func generateToken() {
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

    func rotateToken() {
        do {
            generatedToken = try tokenManager.rotateToken()
            hasBearerToken = true
            tokenStatus = "Token rotated and stored in Keychain"
        } catch {
            tokenStatus = error.localizedDescription
            generatedToken = nil
        }
    }

    func revokeToken() {
        do {
            try tokenManager.revokeToken()
            generatedToken = nil
            hasBearerToken = false
            tokenStatus = "Token revoked"
        } catch {
            tokenStatus = error.localizedDescription
        }
    }

    func refreshTokenStatus() {
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

    func copyToClipboard(_ token: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        tokenStatus = "Token copied to clipboard."
    }
}
