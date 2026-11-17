import Darwin
import Foundation

extension AppReleaseVerifier {

    // MARK: - Locating the app

    static func locateApp(in directory: URL, bundleID: String) throws(AppReleaseVerificationFailure) -> URL {
        try uniqueMatch(matchingApps(in: directory, bundleID: bundleID))
    }

    /// The one app found, or a failure for none or several.
    static func uniqueMatch(_ matches: [URL]) throws(AppReleaseVerificationFailure) -> URL {
        guard let match = matches.first else { throw .appNotFound }
        guard matches.count == 1 else { throw .multipleMatchingApps }
        return match
    }

    /// Top-level `.app` directories (never symlinks) whose Info.plist names
    /// `bundleID`. `__MACOSX` and hidden entries are ignored.
    static func matchingApps(in directory: URL, bundleID: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), name != "__MACOSX", name.lowercased().hasSuffix(".app") else { return nil }
            let url = directory.appendingPathComponent(name, isDirectory: true)
            guard AppBundleFiles.fileType(atPath: url.path) == S_IFDIR,
                  AppBundleFiles.infoPlist(ofBundle: url)?["CFBundleIdentifier"] as? String == bundleID
            else { return nil }
            return url
        }
    }

    // MARK: - Tree walk

    /// Walks the bundle without following symlinks. Allows only directories,
    /// regular files, and relative symlinks that resolve inside the bundle
    /// both lexically and on disk.
    static func walkBundleTree(_ bundle: URL) throws(AppReleaseVerificationFailure) {
        let root = bundle.path
        guard let resolvedRoot = AppBundleFiles.realPath(root) else { throw .appNotFound }

        var pending = [""]
        while let relativeDirectory = pending.popLast() {
            let directory = relativeDirectory.isEmpty ? root : root + "/" + relativeDirectory
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory)
            } catch {
                throw .unreadablePayload(error.localizedDescription)
            }
            for name in names {
                let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                let path = root + "/" + relative
                switch AppBundleFiles.fileType(atPath: path) {
                case S_IFDIR:
                    pending.append(relative)
                case S_IFREG:
                    continue
                case S_IFLNK:
                    try checkSymlink(atPath: path, relative: relative, resolvedRoot: resolvedRoot)
                default:
                    throw .specialFile(relative)
                }
            }
        }
        guard AppBundleFiles.fileType(atPath: root + "/Contents/Info.plist") == S_IFREG else { throw .missingInfoPlist }
    }

    private static func checkSymlink(
        atPath path: String,
        relative: String,
        resolvedRoot: String
    ) throws(AppReleaseVerificationFailure) {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              !target.isEmpty, !target.hasPrefix("/")
        else { throw .symlinkEscapesBundle(relative) }

        var components = relative.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/") where component != "." {
            if component == ".." {
                guard components.popLast() != nil else { throw .symlinkEscapesBundle(relative) }
            } else {
                components.append(String(component))
            }
        }

        guard let resolved = AppBundleFiles.realPath(path),
              resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
        else { throw .symlinkEscapesBundle(relative) }
    }

    // MARK: - Helpers

    static func makeEmptyDirectory(_ url: URL) throws(AppReleaseVerificationFailure) {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .extractionFailed(error.localizedDescription)
        }
    }
}
