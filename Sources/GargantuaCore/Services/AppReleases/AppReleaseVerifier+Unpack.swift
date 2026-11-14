import Darwin
import Foundation

extension AppReleaseVerifier {

    // MARK: - Archive entries and extraction

    /// Rejects absolute paths, any `..` component, and empty names. Also
    /// rejects an entry under a path that another entry stores as a file or
    /// symlink (no trailing `/`): extracting a symlink and then a child
    /// through it writes outside the destination on extractors that follow
    /// the link (CVE-2025-31198). Paths are compared without `.` or empty
    /// components, ignoring case and Unicode normalization, as APFS does.
    static func validateArchiveEntries(_ paths: [String]) throws(AppReleaseVerificationFailure) {
        var leaves = Set<String>()
        for path in paths {
            guard !path.isEmpty else { throw .unsafeArchiveEntry("(empty name)") }
            guard !path.hasPrefix("/") else { throw .unsafeArchiveEntry(path) }
            if path.split(separator: "/").contains("..") { throw .unsafeArchiveEntry(path) }
            if !path.hasSuffix("/") { leaves.insert(archiveKey(archiveComponents(path))) }
        }
        for path in paths {
            let components = archiveComponents(path)
            for length in components.indices.dropFirst() where leaves.contains(archiveKey(components[..<length])) {
                throw .unsafeArchiveEntry(path)
            }
        }
    }

    private static func archiveComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    private static func archiveKey(_ components: some Sequence<String>) -> String {
        components.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Disk space

    static let minimumFreeBytes: Int64 = 1_073_741_824
    static let maxExtractedBytes: Int64 = 16 * 1_073_741_824

    /// Unpacking needs four times the payload free, and never less than
    /// 1 GiB. Free space that can't be read fails the same way.
    static func checkFreeSpace(available: Int64?, payloadSize: Int64) throws(AppReleaseVerificationFailure) {
        let fourTimes = payloadSize > Int64.max / 4 ? Int64.max : payloadSize * 4
        let needed = max(fourTimes, minimumFreeBytes)
        guard let available, available >= needed else {
            throw .insufficientDiskSpace(needed: needed, available: available)
        }
    }

    static func checkExtractedSize(_ size: Int64) throws(AppReleaseVerificationFailure) {
        guard size <= maxExtractedBytes else { throw .extractedTooLarge(limit: maxExtractedBytes) }
    }

    static func availableCapacity(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Total size of the regular files under `root`, without following
    /// links. Stops counting once past `limit`.
    static func treeSize(of root: URL, limit: Int64) throws(AppReleaseVerificationFailure) -> Int64 {
        var total: Int64 = 0
        var pending = [root.path]
        while let directory = pending.popLast() {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory)
            } catch {
                throw .unreadablePayload(error.localizedDescription)
            }
            for name in names {
                let path = directory + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { throw .unreadablePayload(String(cString: strerror(errno))) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    pending.append(path)
                case S_IFREG:
                    total += Int64(info.st_size)
                    if total > limit { return total }
                default:
                    continue
                }
            }
        }
        return total
    }

    // MARK: - Unpacking

    func unpack(
        _ payload: URL,
        kind: AppReleasePayloadKind,
        into destination: URL,
        mountRoot: URL,
        bundleID: String
    ) throws(AppReleaseVerificationFailure) {
        switch kind {
        case .zip:
            try Self.validateArchiveEntries(listArchive("/usr/bin/zipinfo", ["-1", payload.path]))
            try runChecked("/usr/bin/ditto", ["-x", "-k", payload.path, destination.path], timeout: 900)
        case .tar:
            try Self.validateArchiveEntries(listArchive("/usr/bin/tar", ["-tf", payload.path]))
            try runChecked("/usr/bin/tar", ["-xf", payload.path, "-C", destination.path], timeout: 900)
        case .dmg:
            try copyApp(fromDiskImage: payload, into: destination, mountRoot: mountRoot, bundleID: bundleID)
        case .pkg:
            throw .installerPackage
        case .unknown:
            throw .unrecognizedPayload
        }
    }

    private func listArchive(_ tool: String, _ arguments: [String]) throws(AppReleaseVerificationFailure) -> [String] {
        let output = try runChecked(tool, arguments, timeout: 120, maxCapturedBytes: Self.maxListingBytes)
        guard !output.stdoutTruncated else { throw .extractionFailed("the archive listing is too long") }
        var lines = output.stdout.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Mounts the image read-only, copies the one matching app out with
    /// `ditto`, and always detaches. The mounted volume is never the install
    /// source.
    private func copyApp(
        fromDiskImage image: URL,
        into destination: URL,
        mountRoot: URL,
        bundleID: String
    ) throws(AppReleaseVerificationFailure) {
        try Self.makeEmptyDirectory(mountRoot)
        defer { detachVolumes(under: mountRoot) }

        let output = try run(
            "/usr/bin/hdiutil",
            [
                "attach", "-readonly", "-nobrowse", "-noautoopen", "-stdinpass",
                "-mountrandom", mountRoot.path, "-plist", image.path,
            ],
            timeout: 120
        )
        guard output.exitCode == 0 else {
            if Self.isLicenseAgreementRefusal(output) { throw .licenseAgreementRequired }
            if (output.stdout + "\n" + output.stderr).lowercased().contains("authentication error") {
                throw .encryptedDiskImage
            }
            throw .extractionFailed(Self.describeFailure("hdiutil", output))
        }
        let mounted = Set(Self.mountedVolumes(under: mountRoot).compactMap(AppBundleFiles.realPath))
        let volumes = Self.mountPoints(fromAttachPlist: output.stdout).filter { mountPoint in
            AppBundleFiles.realPath(mountPoint).map(mounted.contains) ?? false
        }
        guard !volumes.isEmpty else { throw .extractionFailed("hdiutil reported no volume in the staging folder") }

        let source = try Self.uniqueMatch(volumes.flatMap {
            Self.matchingApps(in: URL(fileURLWithPath: $0), bundleID: bundleID)
        })
        let target = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try runChecked("/usr/bin/ditto", [source.path, target.path], timeout: 900)
    }

    /// Detaches everything mounted under `mountRoot`, which also covers an
    /// attach whose plist didn't parse or that timed out after mounting.
    private func detachVolumes(under mountRoot: URL) {
        for mountPoint in Self.mountedVolumes(under: mountRoot) {
            _ = try? runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", "-force", mountPoint],
                timeout: 60
            )
        }
    }

    /// Direct children of `mountRoot` that sit on a different device, i.e.
    /// mount points. A plain directory is never passed to `hdiutil detach`,
    /// which would otherwise act on the volume that contains it.
    static func mountedVolumes(under mountRoot: URL) -> [String] {
        var rootInfo = stat()
        guard lstat(mountRoot.path, &rootInfo) == 0 else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mountRoot.path)) ?? []
        return names.sorted().compactMap { name in
            let path = mountRoot.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_dev != rootInfo.st_dev else {
                return nil
            }
            return path
        }
    }

    static func mountPoints(fromAttachPlist text: String) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil),
              let entities = (plist as? [String: Any])?["system-entities"] as? [[String: Any]]
        else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }
    }

    /// hdiutil reads the agreement prompt from stdin, which a GUI app has
    /// bound to /dev/null; the refusal it sees reports as a cancelled attach.
    static func isLicenseAgreementRefusal(_ output: ProcessOutput) -> Bool {
        let text = (output.stdout + "\n" + output.stderr).lowercased()
        return text.contains("agree y/n") || text.contains("license agreement")
            || text.contains("software license") || text.contains("attach canceled")
            || text.contains("attach cancelled")
    }

    // MARK: - Process helpers

    private static func describeFailure(_ tool: String, _ output: ProcessOutput) -> String {
        let lines = output.stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        return lines.isEmpty ? "\(tool) exited with status \(output.exitCode)" : "\(tool): \(lines)"
    }

    private func run(
        _ tool: String,
        _ arguments: [String],
        timeout: TimeInterval,
        maxCapturedBytes: Int = DefaultProcessRunner.defaultMaxCapturedBytes
    ) throws(AppReleaseVerificationFailure) -> ProcessOutput {
        do {
            return try runner.run(
                executable: URL(fileURLWithPath: tool),
                arguments: arguments,
                timeout: timeout,
                maxCapturedBytes: maxCapturedBytes
            )
        } catch {
            throw .extractionFailed("\(tool): \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func runChecked(
        _ tool: String,
        _ arguments: [String],
        timeout: TimeInterval,
        maxCapturedBytes: Int = DefaultProcessRunner.defaultMaxCapturedBytes
    ) throws(AppReleaseVerificationFailure) -> ProcessOutput {
        let output = try run(tool, arguments, timeout: timeout, maxCapturedBytes: maxCapturedBytes)
        guard output.exitCode == 0 else { throw .extractionFailed(Self.describeFailure(tool, output)) }
        return output
    }
}
