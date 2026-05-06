import Foundation

/// Parser for the textual output of `pkgutil --pkg-info <id>` and
/// `pkgutil --files <id>`.
///
/// `pkgutil`'s `--pkg-info` form prints a small block of `key: value` lines:
/// ```text
/// package-id: com.docker.docker
/// version: 4.30.0
/// volume: /
/// location: /
/// install-time: 1735689600
/// groups: com.docker.pkg-group
/// ```
///
/// `--files` prints one BOM entry per line, relative to the package's
/// `volume + install-location`. Empty lines and blank prefixes appear in the
/// wild and are ignored.
public struct PkgUtilOutputParser: Sendable {
    public init() {}

    /// Parse the output of `pkgutil --pkg-info <pkg-id>` into a
    /// `PackageReceipt`. Returns `nil` when the output is empty or doesn't
    /// contain a `package-id` line — `pkgutil` prints a one-line error to
    /// stderr in those cases and exits non-zero, so the caller should already
    /// have filtered them out.
    public func parsePackageInfo(_ stdout: String) -> PackageReceipt? {
        var pkgID: String?
        var version: String?
        var installDate: Date?
        var volume = "/"
        var location = "/"

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "package-id":
                pkgID = value
            case "version":
                version = value.isEmpty ? nil : value
            case "volume":
                volume = value.isEmpty ? "/" : value
            // pkgutil prints `location:` on macOS 14+, `install-location:` on
            // older releases. Accept both and last-wins in case both appear.
            case "location", "install-location":
                location = value.isEmpty ? "/" : value
            case "install-time":
                installDate = parseInstallTime(value)
            default:
                continue
            }
        }

        guard let pkgID, !pkgID.isEmpty else { return nil }

        return PackageReceipt(
            pkgID: pkgID,
            version: version,
            installDate: installDate,
            volume: volume,
            installLocation: location
        )
    }

    /// Parse the output of `pkgutil --files <pkg-id>` into the relative BOM
    /// entries. The caller resolves these against `PackageReceipt`.
    public func parseFiles(_ stdout: String) -> [String] {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse the output of `pkgutil --pkgs` into a list of package IDs. Each
    /// non-empty line is a single package identifier; trim whitespace and
    /// drop blank lines.
    public func parsePackageList(_ stdout: String) -> [String] {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Internal

    private func parseInstallTime(_ raw: String) -> Date? {
        guard let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
