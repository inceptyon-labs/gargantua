import Foundation

extension AppReleaseInstaller {
    /// What the download a brew upgrade would install holds, against the copy
    /// on disk.
    enum BrewPreflight: Equatable {
        /// Newer, or not known to be older: brew decides, as it does without
        /// the preflight.
        case proceed
        /// The same version or a provably older one. `isOfferedRelease` is
        /// false when brew's cask names another version than the row offered.
        case notNewer(staged: AppReleaseVersion, isOfferedRelease: Bool)
    }

    /// Fetches the cask into brew's download cache, where `brew upgrade`
    /// installs it from, and reads the app's version there first. Brew decides
    /// a named cask is outdated from its own record of the installed version
    /// alone, never the app on disk, so an app that updated itself past the
    /// cask would otherwise be replaced by the older build.
    ///
    /// Only a version that is provably not newer stops the upgrade. A download
    /// that can't be read or ordered leaves the decision to brew; a fetch that
    /// fails is reported, since the upgrade would fail on it too.
    @MainActor
    // swiftlint:disable:next function_parameter_count
    func brewPreflight(
        _ brew: URL,
        token: String,
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        before: AppReleaseVersion,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async throws(AppReleaseInstallError) -> BrewPreflight {
        progress(.downloading(received: 0, expected: nil))
        // `brew upgrade` refreshes brew's cask list itself; `fetch` doesn't.
        _ = await runDetached(brew, ["update-if-needed"])
        let fetch: ProcessOutput
        do {
            fetch = try await runDetached(brew, ["fetch", "--cask", token]).get()
        } catch {
            throw .brewFailed(error.localizedDescription)
        }
        guard fetch.exitCode == 0 else { throw .brewFailed(Self.lastLines(of: fetch)) }

        guard let payload = await cachedDownload(brew, token: token) else { return .proceed }
        progress(.verifying)
        let staged: AppReleaseVersion
        do {
            staged = try await bundledVersion(of: app.bundleID, in: payload)
        } catch {
            appReleaseInstallLogger.notice(
                "brew preflight for \(token, privacy: .public) couldn't read the download: \(error.localizedDescription, privacy: .public)"
            )
            return .proceed
        }
        guard staged.description == before.description || staged.compare(to: before) == .orderedAscending else {
            return .proceed
        }
        let brewVersion = await caskVersion(brew, token: token)
        return .notNewer(staged: staged, isOfferedRelease: brewVersion != nil && brewVersion == candidate.caskVersion)
    }

    /// The path `brew --cache` names for the cask's download. Anything that
    /// isn't a fetched file fails to read and leaves the decision to brew.
    private func cachedDownload(_ brew: URL, token: String) async -> URL? {
        guard let output = try? await runDetached(brew, ["--cache", "--cask", token]).get(), output.exitCode == 0,
              let path = output.stdout.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The version of brew's own definition of the cask, which the fetched
    /// download belongs to.
    private func caskVersion(_ brew: URL, token: String) async -> String? {
        guard let output = try? await runDetached(brew, ["info", "--cask", "--json=v2", token]).get(),
              output.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
              let cask = (json["casks"] as? [[String: Any]])?.first
        else { return nil }
        return cask["version"] as? String
    }

    /// Unpacks in a staging folder of its own, removed afterwards.
    private func bundledVersion(of bundleID: String, in payload: URL) async throws -> AppReleaseVersion {
        let workDirectory = try Self.makeStagingDirectory(in: stagingRoot)
        let verifier = verifier
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(AppReleaseVerificationFailure) in
                try verifier.bundledVersion(of: bundleID, in: payload, workDirectory: workDirectory)
            }
        }.value
        await Self.removeStagingDirectory(workDirectory)
        return try result.get()
    }

    /// Runs brew off the main actor.
    func runDetached(_ brew: URL, _ arguments: [String]) async -> Result<ProcessOutput, any Error> {
        let runner = runner
        return await Task.detached(priority: .userInitiated) {
            Result {
                try runner.run(
                    executable: brew,
                    arguments: arguments,
                    timeout: Self.brewTimeout,
                    maxCapturedBytes: Self.brewCaptureBytes
                )
            }
        }.value
    }
}
