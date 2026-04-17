import AppKit
import Foundation

/// Raw metadata extracted from an app bundle's Info.plist and filesystem attributes.
///
/// This is the scanner's intermediate shape; the final `AppInfo` combines it with
/// running-state, signature, and size information.
public struct AppBundleMetadata: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let displayName: String?
    public let shortVersion: String?
    public let bundleVersion: String?
    public let bundlePath: String
    public let executablePath: String?
    public let installDate: Date?
    public let lastUsedDate: Date?

    public init(
        bundleID: String,
        name: String,
        displayName: String? = nil,
        shortVersion: String? = nil,
        bundleVersion: String? = nil,
        bundlePath: String,
        executablePath: String? = nil,
        installDate: Date? = nil,
        lastUsedDate: Date? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.installDate = installDate
        self.lastUsedDate = lastUsedDate
    }
}

/// Abstraction over Info.plist + filesystem metadata extraction.
public protocol AppBundleReading: Sendable {
    /// Returns metadata for a bundle, or `nil` if the bundle can't be read
    /// (missing Info.plist, no bundleID, etc.).
    func readMetadata(bundleURL: URL) -> AppBundleMetadata?

    /// Apparent on-disk size of the bundle in bytes, computed recursively.
    /// Returns `nil` if the size could not be measured.
    func sizeOnDisk(bundleURL: URL) -> Int64?
}

/// Default reader backed by `Bundle` and `FileManager`.
public struct DefaultAppBundleReader: AppBundleReading {
    public init() {}

    public func readMetadata(bundleURL: URL) -> AppBundleMetadata? {
        let fileManager = FileManager.default
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            return nil
        }

        let name = (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let displayName = info["CFBundleDisplayName"] as? String
        let shortVersion = info["CFBundleShortVersionString"] as? String
        let bundleVersion = info["CFBundleVersion"] as? String

        let executablePath: String? = {
            if let executableURL = bundle.executableURL {
                return executableURL.path
            }
            if let executableName = info["CFBundleExecutable"] as? String {
                return bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)").path
            }
            return nil
        }()

        let attrs = try? fileManager.attributesOfItem(atPath: bundleURL.path)
        let installDate = attrs?[.creationDate] as? Date
        let lastUsedDate = resolveLastUsedDate(
            bundleURL: bundleURL,
            executablePath: executablePath,
            fallback: attrs?[.modificationDate] as? Date
        )

        return AppBundleMetadata(
            bundleID: bundleID,
            name: name,
            displayName: displayName.flatMap { $0 == name ? nil : $0 },
            shortVersion: shortVersion,
            bundleVersion: bundleVersion,
            bundlePath: bundleURL.path,
            executablePath: executablePath,
            installDate: installDate,
            lastUsedDate: lastUsedDate
        )
    }

    public func sizeOnDisk(bundleURL: URL) -> Int64? {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: bundleURL,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [],
                errorHandler: { _, _ in true }
            )
        else {
            return nil
        }

        var total: Int64 = 0
        var measuredAnything = false
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
            ])
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
            if let size {
                total += Int64(size)
                measuredAnything = true
            }
        }
        return measuredAnything ? total : nil
    }

    /// Use the executable's access timestamp as a proxy for "last launched",
    /// falling back to the bundle's modification date. Neither is perfect —
    /// `kMDItemLastUsedDate` is the canonical source but requires Spotlight
    /// indexing — but this approximation works on every volume.
    private func resolveLastUsedDate(
        bundleURL: URL,
        executablePath: String?,
        fallback: Date?
    ) -> Date? {
        let fileManager = FileManager.default
        if let executablePath,
            let attrs = try? fileManager.attributesOfItem(atPath: executablePath),
            let accessDate = attrs[.modificationDate] as? Date {
            return accessDate
        }
        return fallback
    }
}
