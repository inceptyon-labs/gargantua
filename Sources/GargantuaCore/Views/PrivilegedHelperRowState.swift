import Foundation

/// What the Permissions row should say about the privileged helper.
///
/// `SMAppService.Status` alone is not enough: `.notFound` covers both "no helper
/// in this build" and "helper is right there but macOS won't register it" (app
/// outside /Applications, quarantined or translocated copy, stale Background
/// Task Management record). Folding in bundle presence separates the two.
public enum PrivilegedHelperRowState: Equatable {
    case granted
    case needsApproval
    case registrationRefused
    case notBundled
    case statusUnknown(Int)

    public init(status: PrivilegedHelperStatus, isHelperBundled: Bool) {
        switch status {
        case .enabled: self = .granted
        case .requiresApproval, .notRegistered: self = .needsApproval
        case .notFound: self = isHelperBundled ? .registrationRefused : .notBundled
        case .unknown(let rawValue): self = .statusUnknown(rawValue)
        }
    }

    /// Whether the row should offer the button that re-registers and deep-links
    /// to Login Items. `.notBundled` has nothing to register; `.granted` is done.
    public var offersRegistrationRetry: Bool {
        switch self {
        case .granted, .notBundled: false
        case .needsApproval, .registrationRefused, .statusUnknown: true
        }
    }

    /// Copy for the Permissions row's detail line. Doesn't cover the
    /// `registerError` override — that's a runtime message the view still owns.
    public var detail: String {
        switch self {
        case .granted:
            "Approved — Gargantua can remove system-owned items (helpers, prefpanes, root caches)."
        case .needsApproval:
            "Not approved — system-owned items can’t be removed until you enable Gargantua under "
                + "Login Items & Extensions."
        case .registrationRefused:
            "Included in this build, but macOS hasn’t registered it — system-owned items can’t be "
                + "removed yet. Make sure Gargantua is in your Applications folder, then enable it "
                + "under Login Items & Extensions."
        case .notBundled:
            "Not included in this build — system-owned items can’t be removed. The signed release "
                + "ships the helper; files you own are still cleaned."
        case .statusUnknown:
            "Status unknown — check Gargantua under Login Items & Extensions."
        }
    }
}
