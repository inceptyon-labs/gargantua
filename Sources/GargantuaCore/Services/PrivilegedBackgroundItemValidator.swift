import Foundation

/// Validates `PrivilegedBackgroundItemRequest` payloads inside the privileged
/// helper before any subprocess or trash op runs. The validator is intentionally
/// pure (no side effects beyond `FileManager` lookups) so it can be unit-tested
/// from within `GargantuaCore` without involving the helper binary.
public struct PrivilegedBackgroundItemValidator: Sendable {
    /// Filesystem accessor; injected so tests can fake existence/symlinks
    /// without writing to `/Library/LaunchDaemons/` for real.
    public struct FileSystem: Sendable {
        public let fileExists: @Sendable (String, UnsafeMutablePointer<ObjCBool>?) -> Bool
        public let resolvedSymlinkPath: @Sendable (String) -> String

        public init(
            fileExists: @escaping @Sendable (String, UnsafeMutablePointer<ObjCBool>?) -> Bool,
            resolvedSymlinkPath: @escaping @Sendable (String) -> String
        ) {
            self.fileExists = fileExists
            self.resolvedSymlinkPath = resolvedSymlinkPath
        }

        public static let live = FileSystem(
            fileExists: { path, isDir in FileManager.default.fileExists(atPath: path, isDirectory: isDir) },
            resolvedSymlinkPath: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        )
    }

    /// Allow-listed parent directories for plist operations. `/System/` and
    /// `/Library/PrivilegedHelperTools/` are intentionally excluded — those
    /// belong to the OS or to other helpers, not to user-initiated cleanup.
    public static let allowedPlistDirectories: Set<String> = [
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
    ]

    /// Label format: starts with an alphanumeric, then `[A-Za-z0-9._-]` up to
    /// 254 chars. Excludes spaces, slashes, parent traversal, and any control
    /// characters that could let a label inject extra `launchctl` args.
    public static let labelPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"

    private let fs: FileSystem
    private let labelRegex: NSRegularExpression

    public init(fileSystem: FileSystem = .live) {
        self.fs = fileSystem
        // The pattern is a compile-time constant. A regex failure here would
        // be a programming bug, so we surface it as a fatal — never as a
        // helper-side runtime path the caller has to handle.
        guard let regex = try? NSRegularExpression(pattern: Self.labelPattern) else {
            preconditionFailure("PrivilegedBackgroundItemValidator: invalid built-in label pattern")
        }
        self.labelRegex = regex
    }

    public func validate(_ request: PrivilegedBackgroundItemRequest) throws {
        try validateLabel(request.label)
        try validateOperationContext(request)
    }

    // MARK: - Label validation

    private func validateLabel(_ label: String) throws {
        guard !label.isEmpty else {
            throw PrivilegedBackgroundItemValidationError.invalidLabel(label)
        }
        let range = NSRange(label.startIndex ..< label.endIndex, in: label)
        guard labelRegex.firstMatch(in: label, range: range) != nil else {
            throw PrivilegedBackgroundItemValidationError.invalidLabel(label)
        }
        if label.hasPrefix("com.apple.") {
            throw PrivilegedBackgroundItemValidationError.appleLabelRejected(label)
        }
    }

    // MARK: - Operation-specific validation

    private func validateOperationContext(_ request: PrivilegedBackgroundItemRequest) throws {
        switch request.operation {
        case .bootoutDaemon, .disableDaemon, .enableDaemon:
            // Pure label ops — no path needed; the launchctl target is
            // `system/<label>` which the helper builds itself.
            return
        case .bootstrapDaemon:
            guard let path = request.plistPath else {
                throw PrivilegedBackgroundItemValidationError.missingPlistPath
            }
            try validatePlistPath(path, label: request.label)
            // `bootstrap` requires the plist to exist on disk so launchd
            // can read it.
            try requireFileExists(path)
        case .trashLaunchPlist:
            guard let path = request.plistPath else {
                throw PrivilegedBackgroundItemValidationError.missingPlistPath
            }
            try validatePlistPath(path, label: request.label)
            try requireFileExists(path)
        }
    }

    // MARK: - Path validation

    private func validatePlistPath(_ path: String, label: String) throws {
        // Reject any path that doesn't standardize back to itself — kills
        // `..` traversal, double slashes, and trailing components without
        // re-walking the filesystem ourselves.
        let url = URL(fileURLWithPath: path)
        let standardized = url.standardizedFileURL
        guard standardized.path == path else {
            throw PrivilegedBackgroundItemValidationError.rejectedPath(path)
        }

        // Reject symlinks anywhere along the path. We compare against the
        // standardized path, not the raw input — symlinks resolve through
        // both, so the equality check catches any link short-circuit.
        let resolved = fs.resolvedSymlinkPath(standardized.path)
        guard resolved == standardized.path else {
            throw PrivilegedBackgroundItemValidationError.symlinkRejected(path)
        }

        // Parent directory must be exactly one of the allow-listed roots.
        let parent = url.deletingLastPathComponent().path
        guard Self.allowedPlistDirectories.contains(parent) else {
            throw PrivilegedBackgroundItemValidationError.rejectedPath(path)
        }

        // Filename must be `<label>.plist` — prevents disabling label X while
        // pointing the trash op at plist Y.
        let filename = url.lastPathComponent
        guard filename == "\(label).plist" else {
            throw PrivilegedBackgroundItemValidationError.labelPathMismatch(label: label, path: path)
        }
    }

    private func requireFileExists(_ path: String) throws {
        var isDir: ObjCBool = false
        guard fs.fileExists(path, &isDir), !isDir.boolValue else {
            throw PrivilegedBackgroundItemValidationError.missingPath(path)
        }
    }

    // MARK: - Subprocess argument builders

    /// Build the launchctl argv vector for a given operation. The helper calls
    /// this so the same argument shape is also unit-testable from outside the
    /// helper binary.
    public static func launchctlArguments(
        for operation: PrivilegedBackgroundItemOperation,
        label: String,
        plistPath: String?
    ) -> [String]? {
        switch operation {
        case .bootoutDaemon:
            return ["bootout", "system/\(label)"]
        case .disableDaemon:
            return ["disable", "system/\(label)"]
        case .enableDaemon:
            return ["enable", "system/\(label)"]
        case .bootstrapDaemon:
            guard let plistPath else { return nil }
            return ["bootstrap", "system", plistPath]
        case .trashLaunchPlist:
            return nil
        }
    }
}

public enum PrivilegedBackgroundItemValidationError: Error, LocalizedError, Equatable {
    case invalidLabel(String)
    case appleLabelRejected(String)
    case missingPlistPath
    case rejectedPath(String)
    case symlinkRejected(String)
    case labelPathMismatch(label: String, path: String)
    case missingPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLabel(let label):
            "Privileged helper rejected label: \(label.isEmpty ? "<empty>" : label)"
        case .appleLabelRejected(let label):
            "Privileged helper refuses to operate on Apple-namespaced label: \(label)"
        case .missingPlistPath:
            "Privileged helper request is missing the plist path."
        case .rejectedPath(let path):
            "Privileged helper rejected plist path: \(path)"
        case .symlinkRejected(let path):
            "Privileged helper rejected symlinked plist path: \(path)"
        case .labelPathMismatch(let label, let path):
            "Privileged helper rejected label/path mismatch: label=\(label) path=\(path)"
        case .missingPath(let path):
            "Privileged helper plist path does not exist (or is a directory): \(path)"
        }
    }
}
