import SwiftUI

extension MCPTransportSettingsSection {
    enum DestructiveAction: Identifiable {
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
                "The current token stops working immediately and a new one replaces it in Keychain. "
                    + "Any MCP client using the old token will lose access."
            case .revoke:
                "The token is deleted from Keychain. MCP clients will be locked out until a new token "
                    + "is generated. This cannot be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .rotate: "Rotate token"
            case .revoke: "Revoke token"
            }
        }
    }
}
