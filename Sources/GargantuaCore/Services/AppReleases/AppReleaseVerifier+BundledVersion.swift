import Foundation

extension AppReleaseVerifier {
    /// A disk image is read where it mounts, without copying the app out; an
    /// archive is unpacked with the same entry and size checks as `verify`.
    public func bundledVersion(
        of bundleID: String,
        in payload: URL,
        workDirectory: URL
    ) throws(AppReleaseVerificationFailure) -> AppReleaseVersion {
        let payloadSize = try Self.checkLength(of: payload, expected: nil)
        let kind = try Self.sniffPayload(payload, declared: .unknown)
        let mountRoot = workDirectory.appendingPathComponent("mounts", isDirectory: true)
        if kind == .dmg {
            return try withMountedDiskImage(payload, mountRoot: mountRoot) { volumes throws(AppReleaseVerificationFailure) in
                let matches = volumes.flatMap { Self.matchingApps(in: URL(fileURLWithPath: $0), bundleID: bundleID) }
                return try Self.bundleVersion(of: Self.uniqueMatch(matches))
            }
        }
        let extracted = workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try Self.makeEmptyDirectory(extracted)
        let available = Self.availableCapacity(at: workDirectory)
        try Self.checkFreeSpace(available: available, payloadSize: payloadSize)
        try unpack(
            payload,
            kind: kind,
            into: extracted,
            mountRoot: mountRoot,
            bundleID: bundleID,
            budget: Self.extractionBudget(available: available)
        )
        return try Self.bundleVersion(of: Self.locateApp(in: extracted, bundleID: bundleID))
    }

    fileprivate static func bundleVersion(of bundle: URL) throws(AppReleaseVerificationFailure) -> AppReleaseVersion {
        guard let plist = AppBundleFiles.infoPlist(ofBundle: bundle) else { throw .missingInfoPlist }
        return AppReleaseVersion(plist: plist)
    }
}
