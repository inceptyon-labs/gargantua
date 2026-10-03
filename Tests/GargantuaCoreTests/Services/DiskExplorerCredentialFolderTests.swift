import Foundation
import Testing
@testable import GargantuaCore

@Suite("Disk Explorer credential folders")
struct DiskExplorerCredentialFolderTests {
    @Test("Credential folders, their contents, and folders containing them can't be trashed")
    func credentialFoldersBlocked() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskExplorerCredentialFolderTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        for relative in [".ssh/keys", ".config/gcloud", ".config/other", ".cache"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        let blocked = DiskExplorerTrashDecision.blocked(reason: DiskExplorerTrashPolicy.credentialFolderReason)

        for relative in [".ssh", ".ssh/keys", ".SSH", ".config", ".config/gcloud"] {
            let path = home.appendingPathComponent(relative).path
            #expect(DiskExplorerTrashPolicy.decision(path: path, home: home.path) == blocked, "\(relative)")
            #expect(DiskExplorerTrashPolicy.lexicalDecision(path: path, home: home.path) == blocked, "\(relative)")
        }
        for relative in [".cache", ".config/other"] {
            let path = home.appendingPathComponent(relative).path
            #expect(DiskExplorerTrashPolicy.decision(path: path, home: home.path) == .home, "\(relative)")
        }
    }
}
