// Minimal XPC client for the privileged helper, used by helper-attack.sh.
//
// It does no validation of its own: it forwards raw JSON from stdin to the
// helper and prints the raw reply, so the helper's checks are the only thing
// under test. The selectors below must match PrivilegedUninstallXPCProtocol in
// Sources/GargantuaCore/Models/Uninstaller/PrivilegedUninstallRequest.swift.
//
// Usage: HelperProbe version
//        HelperProbe trash  < request.json   (PrivilegedUninstallRequest)
//        HelperProbe bgitem < request.json   (PrivilegedBackgroundItemRequest)
//
// Output: "VERSION <n>", the helper's JSON reply, "XPC_ERROR <domain> <code> <msg>"
// (exit 3) or "TIMEOUT" (exit 4).

import Foundation

@objc protocol PrivilegedUninstallXPCProtocol {
    func moveItemsToTrash(requestData: Data, withReply reply: @escaping (Data) -> Void)
    func performBackgroundItemAction(requestData: Data, withReply reply: @escaping (Data) -> Void)
    func helperVersion(withReply reply: @escaping (Int) -> Void)
}

final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var text: String?
    private var code: Int32 = 0

    func finish(_ text: String, code: Int32 = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard self.text == nil else { return }
        self.text = text
        self.code = code
        done.signal()
    }

    func wait(seconds: Double) -> (String, Int32)? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return (text ?? "", code)
    }
}

let machService = ProcessInfo.processInfo.environment["HELPER_MACH_SERVICE"]
    ?? "com.inceptyon.gargantua.privileged-helper"
let mode = CommandLine.arguments.dropFirst().first ?? ""
guard ["version", "trash", "bgitem"].contains(mode) else {
    FileHandle.standardError.write(Data("usage: HelperProbe version|trash|bgitem\n".utf8))
    exit(2)
}

let connection = NSXPCConnection(machServiceName: machService, options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedUninstallXPCProtocol.self)
connection.resume()

let outcome = Outcome()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    let ns = error as NSError
    outcome.finish("XPC_ERROR \(ns.domain) \(ns.code) \(ns.localizedDescription)", code: 3)
} as? PrivilegedUninstallXPCProtocol

guard let proxy else {
    print("XPC_ERROR probe 0 could not build remote proxy")
    exit(3)
}

// Lossy on purpose: a malformed reply should still be printed for the script to report.
// swiftlint:disable:next optional_data_string_conversion
let replyText: (Data) -> Void = { outcome.finish(String(decoding: $0, as: UTF8.self)) }
switch mode {
case "version":
    proxy.helperVersion { outcome.finish("VERSION \($0)") }
case "trash":
    proxy.moveItemsToTrash(requestData: FileHandle.standardInput.readDataToEndOfFile(), withReply: replyText)
default:
    proxy.performBackgroundItemAction(requestData: FileHandle.standardInput.readDataToEndOfFile(), withReply: replyText)
}

guard let (text, code) = outcome.wait(seconds: 15) else {
    print("TIMEOUT")
    exit(4)
}
print(text)
connection.invalidate()
exit(code)
