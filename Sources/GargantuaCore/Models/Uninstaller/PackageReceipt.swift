import Foundation

/// A single macOS package receipt as reported by `pkgutil`.
///
/// Receipts are *evidence* that an installer placed files on disk under a
/// given package ID — they are **not** permission to delete. Per the Trust
/// Layer model, BOM-derived candidate paths must still flow through the
/// normal safety classifier (protected roots, shared-system paths,
/// sensitive-data preflight) before they can become actionable.
public struct PackageReceipt: Codable, Sendable, Equatable, Identifiable {
    /// Reverse-DNS package identifier (e.g., `com.docker.docker`).
    public let pkgID: String

    /// Package version string from the receipt, when present.
    public let version: String?

    /// Time the package was installed, when readable from `install-time`.
    public let installDate: Date?

    /// Receipt's `volume` (e.g., `/`). BOM paths are relative to
    /// `volume + location`.
    public let volume: String

    /// Receipt's `location` / `install-location` (e.g., `/`). Combined with
    /// `volume` to resolve relative BOM entries to absolute paths.
    public let installLocation: String

    public var id: String { pkgID }

    public init(
        pkgID: String,
        version: String? = nil,
        installDate: Date? = nil,
        volume: String = "/",
        installLocation: String = "/"
    ) {
        self.pkgID = pkgID
        self.version = version
        self.installDate = installDate
        self.volume = volume
        self.installLocation = installLocation
    }

    /// Resolve a BOM-relative path against the receipt's volume +
    /// install-location. Returns an absolute path with redundant separators
    /// collapsed. The path is *not* checked for existence here — that's the
    /// expander's responsibility.
    public func absolutePath(for bomEntry: String) -> String {
        let trimmed = bomEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let base = (volume as NSString).appendingPathComponent(installLocation)
        let joined = (base as NSString).appendingPathComponent(trimmed)
        return (joined as NSString).standardizingPath
    }
}
