import Foundation
import GargantuaCore
import Security

private final class PrivilegedHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let validator = CallerCodeSignatureValidator()
    private let service = PrivilegedUninstallXPCService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validator.validate(connection: connection) else {
            HelperLog.write("rejected connection from pid \(connection.processIdentifier)")
            return false
        }
        HelperLog.write("accepted connection from pid \(connection.processIdentifier)")
        connection.exportedInterface = NSXPCInterface(with: PrivilegedUninstallXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class PrivilegedUninstallXPCService: NSObject, PrivilegedUninstallXPCProtocol {
    func moveItemsToTrash(
        requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        do {
            let request = try PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedUninstallRequest.self,
                from: requestData
            )
            let results = request.items.map(remove)
            let response = PrivilegedUninstallResponse(items: results)
            reply(try PrivilegedUninstallXPCCodec.encoder.encode(response))
        } catch {
            let response = PrivilegedUninstallErrorResponse(error: error.localizedDescription)
            let data = (try? PrivilegedUninstallXPCCodec.encoder.encode(response)) ?? Data()
            reply(data)
        }
    }

    private func remove(_ item: PrivilegedUninstallItem) -> PrivilegedUninstallItemResult {
        do {
            let url = try validate(item)
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            return PrivilegedUninstallItemResult(
                id: item.id,
                path: item.path,
                succeeded: true,
                trashPath: (trashURL as URL?)?.path
            )
        } catch {
            return PrivilegedUninstallItemResult(
                id: item.id,
                path: item.path,
                succeeded: false,
                error: error.localizedDescription
            )
        }
    }

    private func validate(_ item: PrivilegedUninstallItem) throws -> URL {
        guard item.operation == .moveToTrash else {
            throw PrivilegedHelperError.unsupportedOperation(item.operation.rawValue)
        }

        let url = URL(fileURLWithPath: item.path)
        let standardized = url.standardizedFileURL
        guard standardized.path == item.path else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }

        let symlinkResolved = standardized.resolvingSymlinksInPath()
        guard symlinkResolved.path == standardized.path else {
            throw PrivilegedHelperError.symlinkRejected(item.path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            throw PrivilegedHelperError.missingPath(item.path)
        }

        guard isAllowed(standardized, isDirectory: isDirectory.boolValue) else {
            throw PrivilegedHelperError.rejectedPath(item.path)
        }

        return standardized
    }

    private func isAllowed(_ url: URL, isDirectory: Bool) -> Bool {
        let path = url.path
        if path.hasPrefix("/Applications/"),
           path.hasSuffix(".app"),
           isDirectory {
            return isDirectChild(path, of: "/Applications")
        }

        if path.hasPrefix("/Library/LaunchDaemons/"),
           path.hasSuffix(".plist"),
           !isDirectory {
            return isDirectChild(path, of: "/Library/LaunchDaemons")
        }

        if path.hasPrefix("/Library/PrivilegedHelperTools/") {
            return isDirectChild(path, of: "/Library/PrivilegedHelperTools")
        }

        return false
    }

    private func isDirectChild(_ path: String, of parent: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().path == parent
    }
}

private struct CallerCodeSignatureValidator {
    func validate(connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary
        let copyStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(rawValue: 0),
            &code
        )
        guard copyStatus == errSecSuccess, let code else {
            HelperLog.write("SecCodeCopyGuestWithAttributes failed for pid \(connection.processIdentifier): \(copyStatus)")
            return false
        }

        var error: Unmanaged<CFError>?
        let validateStatus = SecCodeCheckValidityWithErrors(
            code,
            SecCSFlags(rawValue: 0),
            nil,
            &error
        )
        if validateStatus != errSecSuccess {
            let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String? } ?? nil
            HelperLog.write("SecCodeCheckValidityWithErrors failed for pid \(connection.processIdentifier): \(validateStatus) \(message ?? "")")
            return false
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(
            code,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard staticStatus == errSecSuccess, let staticCode else {
            HelperLog.write("SecCodeCopyStaticCode failed for pid \(connection.processIdentifier): \(staticStatus)")
            return false
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard infoStatus == errSecSuccess, let dict = info as? [String: Any] else {
            HelperLog.write("SecCodeCopySigningInformation failed for pid \(connection.processIdentifier): \(infoStatus)")
            return false
        }

        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        guard identifier == PrivilegedHelperConfiguration.appBundleID,
              teamID == PrivilegedHelperConfiguration.teamID else {
            HelperLog.write("caller identity mismatch for pid \(connection.processIdentifier): identifier=\(identifier ?? "nil") teamID=\(teamID ?? "nil")")
            return false
        }
        return true
    }
}

private enum HelperLog {
    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

private enum PrivilegedHelperError: Error, LocalizedError {
    case unsupportedOperation(String)
    case rejectedPath(String)
    case symlinkRejected(String)
    case missingPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let operation):
            "Unsupported privileged helper operation: \(operation)"
        case .rejectedPath(let path):
            "Privileged helper rejected path: \(path)"
        case .symlinkRejected(let path):
            "Privileged helper rejected symlink path: \(path)"
        case .missingPath(let path):
            "Privileged helper path does not exist: \(path)"
        }
    }
}

private let listener = NSXPCListener(machServiceName: PrivilegedHelperConfiguration.helperBundleID)
private let delegate = PrivilegedHelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
