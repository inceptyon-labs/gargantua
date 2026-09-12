import Foundation

/// Static Polar.sh configuration. Only public identifiers live here — the
/// license-key activate/validate/deactivate endpoints are public (no bearer
/// token), so nothing in this file is a secret. The organization ID is a
/// public UUID and the checkout URL is shareable.
public enum LicensePolarConfig {
    /// Inceptyon Labs LLC organization (slug: inceptyon-labs-llc). Public UUID.
    public static let organizationID = "06a0b65b-785b-4970-bef8-8ebf6274f719"

    /// Production API. Swap to `https://sandbox-api.polar.sh/v1` to develop
    /// against Polar's isolated sandbox environment.
    public static let apiBaseURL = URL(string: "https://api.polar.sh/v1")!

    /// Pinned Polar API version, sent as `Polar-Version` on every request.
    /// Unpinned requests follow whichever version Polar currently calls
    /// "Current", which rolls over each quarter — a shipped build would then
    /// silently move to a contract it was never compiled against. Polar keeps
    /// a version usable for roughly nine months, so this needs a bump (and a
    /// release) before the pinned version is removed.
    public static let apiVersion = "2026-04"

    /// Hosted checkout link for the Gargantua product. Opened by the "Buy" CTA.
    public static let checkoutURL = URL(
        string: "https://buy.polar.sh/polar_cl_NrgUcsS3Cz6LespqGpiQ42pYnpdo8vi345tYG0uglbC"
    )!

    /// Polar's hosted customer portal for Inceptyon Labs LLC (slug:
    /// inceptyon-labs-llc). Customers log in with their purchase email (Polar
    /// mails a one-time code) and can deactivate stale device activations
    /// themselves — the self-serve remedy when a reinstalled or replaced Mac
    /// orphans an activation slot and reactivation hits the 3-Mac limit.
    public static let customerPortalURL = URL(
        string: "https://polar.sh/inceptyon-labs-llc/portal"
    )!

    /// How long a cached `granted` validation is trusted without re-checking
    /// the server. Keeps the app usable offline; the background revalidation
    /// extends this window whenever the app is online. 14 days.
    public static let validationGraceInterval: TimeInterval = 14 * 24 * 60 * 60
}
