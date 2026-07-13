import GargantuaLicensing

/// User-facing copy for Polar activation failures. Shared by the Settings pane
/// and the unlock sheet so the messaging stays consistent.
enum LicenseErrorCopy {
    static func message(for error: PolarLicenseError) -> String {
        switch error {
        case .activationLimitReached:
            return "You've activated on the maximum of 3 Macs. Deactivate one on that Mac, or use Manage Devices below to remove one you no longer have, then try again."
        case .notFound:
            return "That license key wasn't found. Check the key from your purchase email and try again."
        case .network:
            return "Couldn't reach the license server. Check your connection and try again."
        case .server(let code, _):
            return "License server error (\(code)). Please try again in a moment."
        case .decoding:
            return "Unexpected response from the license server. Please try again."
        case .receiptSaveFailed:
            return "Your key was activated but couldn't be saved on this Mac, so the activation was released. It's safe to try again."
        }
    }
}
