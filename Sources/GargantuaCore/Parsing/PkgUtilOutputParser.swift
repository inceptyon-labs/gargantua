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

    /// Parse the output of `pkgutil --file-info <path>` into the receipts that
    /// claim ownership of the path.
    ///
    /// `--file-info` prints a leading `volume:`/`path:` block describing the
    /// queried path, then one stanza per owning package:
    /// ```text
    /// volume: /
    /// path: /usr/local/bin/docker
    ///
    /// pkgid: com.docker.docker
    /// pkg-version: 4.30.0
    /// install-time: 1701734400
    /// uid: 0
    /// gid: 0
    /// mode: 100755
    ///
    /// pkgid: com.docker.docker.helper
    /// ...
    /// ```
    /// Stanzas without a `pkgid` line (the leading volume/path block, or
    /// stray output) are dropped. A path that is not in any receipt produces
    /// only the leading block, so this function returns `[]`.
    ///
    /// Last-wins on duplicate keys within a stanza, matching the
    /// `parsePackageInfo` precedent. CRLF line endings are normalised to LF
    /// up front because Swift collapses `\r\n` into one grapheme cluster,
    /// so `split(separator: "\n")` would otherwise see a single line.
    public func parseFileInfo(_ stdout: String) -> [PackageReceipt] {
        let lines = stdout
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        var stanzas: [[String: String]] = []
        var current: [String: String] = [:]

        func flush() {
            if !current.isEmpty {
                stanzas.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flush()
                continue
            }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            current[key] = value
        }
        flush()

        return stanzas.compactMap { stanza -> PackageReceipt? in
            guard let pkgID = stanza["pkgid"], !pkgID.isEmpty else { return nil }
            let version = stanza["pkg-version"].flatMap { $0.isEmpty ? nil : $0 }
            let installDate = stanza["install-time"].flatMap(parseInstallTime)
            let volume = stanza["volume"].flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            let location = stanza["install-location"]
                ?? stanza["location"]
                ?? "/"
            return PackageReceipt(
                pkgID: pkgID,
                version: version,
                installDate: installDate,
                volume: volume,
                installLocation: location.isEmpty ? "/" : location
            )
        }
    }

    // MARK: - Internal

    private func parseInstallTime(_ raw: String) -> Date? {
        guard let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
