import Darwin
import Foundation

extension AppReleaseVerifier {

    // MARK: - 7. Locate the app

    static func locateApp(in directory: URL, bundleID: String) throws(AppReleaseVerificationFailure) -> URL {
        let matches = matchingApps(in: directory, bundleID: bundleID)
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
            guard fileType(atPath: url.path) == S_IFDIR,
                  infoPlist(ofBundle: url)?["CFBundleIdentifier"] as? String == bundleID
            else { return nil }
            return url
        }
    }

    // MARK: - 8. Tree walk

    /// Walks the bundle without following symlinks. Allows only directories,
    /// regular files, and relative symlinks that resolve inside the bundle
    /// both lexically and on disk.
    static func walkBundleTree(_ bundle: URL) throws(AppReleaseVerificationFailure) {
        let root = bundle.path
        guard let resolvedRoot = realPath(root) else { throw .appNotFound }

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
                switch fileType(atPath: path) {
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
        guard fileType(atPath: root + "/Contents/Info.plist") == S_IFREG else { throw .missingInfoPlist }
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

        guard let resolved = realPath(path),
              resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
        else { throw .symlinkEscapesBundle(relative) }
    }

    // MARK: - Bundle helpers

    /// Reads `Contents/Info.plist` with `PropertyListSerialization`, never
    /// `Bundle(url:)` (Foundation caches Bundle instances). `Contents` must be
    /// a real directory and the plist a regular file; neither is followed
    /// through a symlink.
    static func infoPlist(ofBundle bundle: URL) -> [String: Any]? {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard fileType(atPath: contents.path) == S_IFDIR else { return nil }
        let path = contents.appendingPathComponent("Info.plist").path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maxInfoPlistBytes,
              let data = try? handle.readToEnd()
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Version from a bundle's Info.plist on disk, or nil when unreadable.
    static func bundleVersion(at bundle: URL) -> AppReleaseVersion? {
        guard let plist = infoPlist(ofBundle: bundle) else { return nil }
        return AppReleaseVersion(
            short: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String
        )
    }

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

    /// `lstat` file type bits, or nil when the path can't be stat'ed.
    static func fileType(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
