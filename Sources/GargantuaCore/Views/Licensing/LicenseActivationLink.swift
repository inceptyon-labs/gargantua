import Foundation
import GargantuaLicensing
import Observation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.licensing", category: "ActivationLink")

/// Outcome of the most recent `gargantua://activate` deep link, so the app can
/// tell the user what happened.
///
/// A customer who clicks the activation link in their purchase email brings the
/// app forward and then expects *something*. Reporting only to the log means a
/// failed activation looks identical to no click at all — the same dead end that
/// stranded a real customer in July.
@MainActor
@Observable
public final class LicenseActivationLinkModel {
    public static let shared = LicenseActivationLinkModel()

    public struct Outcome: Identifiable, Equatable {
        public let id = UUID()
        public let succeeded: Bool
        public let message: String
    }

    public var outcome: Outcome?

    public init() {}

    public func dismiss() { outcome = nil }
}

/// Handles the `gargantua://activate?key=GARG-…` deep link. Polar's
/// post-checkout redirect (or the license email's auto-activate link) opens
/// this; we parse the key and run it through the same activation path as the
/// Settings pane. No-ops in source builds (the gate is always licensed there).
public enum LicenseActivationLink {
    public static func handle(_ url: URL) {
        guard url.scheme == "gargantua", url.host == "activate" else { return }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            logger.info("Activation link had no key; ignoring")
            return
        }

        Task { @MainActor in
            let result = await LicenseStateModel.shared.activate(key: key)
            switch result {
            case .success:
                logger.info("Activated via deep link")
                LicenseActivationLinkModel.shared.outcome = .init(
                    succeeded: true,
                    message: "Gargantua is unlocked on this Mac."
                )
            case .failure(let error):
                logger.warning("Deep-link activation failed: \(String(describing: error))")
                LicenseActivationLinkModel.shared.outcome = .init(
                    succeeded: false,
                    message: LicenseErrorCopy.message(for: error)
                )
            }
        }
    }
}
