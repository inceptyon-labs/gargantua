import Foundation
import Testing
@testable import GargantuaCore

@Suite("Disk Explorer trash policy")
struct DiskExplorerTrashPolicyTests {
    /// A scratch root under the system temp directory, standing in for both
    /// "Home" and the outside world so tests don't depend on the real Home.
    /// macOS temp dirs resolve through a `/var` → `/private/var` symlink, so
    /// this is pre-resolved the same way the policy resolves paths, keeping
    /// both sides of every comparison consistent.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskExplorerTrashPolicyTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Home itself is not trashable; descendants are")
    func homeAndDescendants() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let file = home.appendingPathComponent("file.txt")
        let nested = home.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: home.path, home: home.path))
        #expect(DiskExplorerTrashPolicy.canTrash(path: file.path, home: home.path))
        #expect(DiskExplorerTrashPolicy.canTrash(path: nested.path, home: home.path))
    }

    @Test("A sibling that shares Home's name as a prefix is not inside Home")
    func prefixSiblingIsNotInsideHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let siblingFile = root.appendingPathComponent("homeX/file.txt")
        try FileManager.default.createDirectory(
            at: siblingFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: siblingFile.path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: siblingFile.path, home: home.path))
    }

    @Test("Root and other paths outside Home are not trashable")
    func rootAndOutsidePaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        #expect(!DiskExplorerTrashPolicy.canTrash(path: "/", home: home.path))
        #expect(!DiskExplorerTrashPolicy.canTrash(path: root.path, home: home.path))
    }

    @Test("A symlink outside Home pointing into Home is not trashable")
    func symlinkOutsideHomePointingIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outsideLink = root.appendingPathComponent("outsideLink")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: home)

        #expect(!DiskExplorerTrashPolicy.canTrash(path: outsideLink.path, home: home.path))
    }

    @Test("A symlink inside Home pointing out of Home is trashable (the link itself)")
    func symlinkInsideHomePointingOut() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outsideTarget = root.appendingPathComponent("outsideTarget")
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        let insideLink = home.appendingPathComponent("insideLink")
        try FileManager.default.createSymbolicLink(at: insideLink, withDestinationURL: outsideTarget)

        #expect(DiskExplorerTrashPolicy.canTrash(path: insideLink.path, home: home.path))
    }

    @Test("A parent-chain symlink outside Home that resolves into Home is not trashable (lexical pre-check fails closed)")
    func parentChainSymlinkResolvesIntoHomeIsNotTrashable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let dir = home.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        let target = alias.appendingPathComponent("file.txt")

        #expect(!DiskExplorerTrashPolicy.canTrash(path: target.path, home: home.path))
    }

    @Test("A symlink inside Home pointing out of Home makes a path through it non-trashable")
    func pathThroughSymlinkInsideHomePointingOut() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outsideTarget = root.appendingPathComponent("outsideTarget")
        try FileManager.default.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideTarget)
        let child = link.appendingPathComponent("child")
        FileManager.default.createFile(atPath: outsideTarget.appendingPathComponent("child").path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: child.path, home: home.path))
    }

    @Test("A mount root under Home, and anything under it, is not trashable")
    func mountRootUnderHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let mount = home.appendingPathComponent("mnt")
        let nested = mount.appendingPathComponent("a/b")
        let other = home.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let isMountRoot: (URL) -> Bool? = { url in
            url.resolvingSymlinksInPath().path == mount.path ? true : false
        }

        #expect(!DiskExplorerTrashPolicy.canTrash(path: mount.path, home: home.path, isMountRoot: isMountRoot))
        #expect(!DiskExplorerTrashPolicy.canTrash(path: nested.path, home: home.path, isMountRoot: isMountRoot))
        #expect(DiskExplorerTrashPolicy.canTrash(path: other.path, home: home.path, isMountRoot: isMountRoot))
    }

    @Test("An unreadable mount check fails closed")
    func unreadableMountCheckFailsClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let file = home.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(!DiskExplorerTrashPolicy.canTrash(path: file.path, home: home.path, isMountRoot: { _ in nil }))
    }

    @Test("recycle(path:) refuses root and never trashes anything")
    @MainActor
    func recycleRefusesRoot() async {
        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            DiskExplorerTrashPolicy.recycle(path: "/") { error in
                continuation.resume(returning: error)
            }
        }

        #expect(error != nil)
    }

    @Test("recycle(path:) refuses a path outside every allowed location and never touches it")
    @MainActor
    func recycleRefusesPathOutsideRealHome() async throws {
        // A nonexistent path under /System/Library — blocked lexically before
        // any filesystem access, so this can never reach the real Trash
        // regardless of where this machine's TMPDIR resolves.
        let outside = "/System/Library/DiskExplorerTrashPolicyTests-recycle-\(UUID().uuidString)"

        let error = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            DiskExplorerTrashPolicy.recycle(path: outside) { error in
                continuation.resume(returning: error)
            }
        }

        #expect(error != nil)
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test("isLexicallyInsideHome covers Home, descendants, prefix siblings, and root")
    func isLexicallyInsideHome() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let descendant = home.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        let prefixSibling = root.appendingPathComponent("homeX/file.txt")
        try FileManager.default.createDirectory(
            at: prefixSibling.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: prefixSibling.path, contents: Data())

        #expect(DiskExplorerTrashPolicy.isLexicallyInsideHome(home.path, home: home.path))
        #expect(DiskExplorerTrashPolicy.isLexicallyInsideHome(descendant.path, home: home.path))
        #expect(!DiskExplorerTrashPolicy.isLexicallyInsideHome(prefixSibling.path, home: home.path))
        #expect(!DiskExplorerTrashPolicy.isLexicallyInsideHome("/", home: home.path))
    }
}

// MARK: - Outside Home

extension DiskExplorerTrashPolicyTests {
    /// A fake Home (with `.Trash`) and fake allowed roots under a temp dir,
    /// firmlink-resolved to the `/private/var/...` form the policy compares in.
    private struct Fixture {
        let root: URL
        let home: URL
        let trash: URL
        let applications: URL
        let library: URL
        let deniedApple: URL
        let protectedDir: URL

        var allowedRoots: [String] { [applications.path, library.path] }
        var deniedSubtrees: [String] { [deniedApple.path] }
        var protectedRoots: ProtectedRootPolicy {
            ProtectedRootPolicy(entries: [ProtectedRootEntry(path: protectedDir.path, reason: "Test protected")])
        }

        func decision(_ url: URL, isMountRoot: (URL) -> Bool? = { _ in false }) -> DiskExplorerTrashDecision {
            DiskExplorerTrashPolicy.decision(
                path: url.path, home: home.path, allowedRoots: allowedRoots,
                deniedSubtrees: deniedSubtrees, protectedRoots: protectedRoots, isMountRoot: isMountRoot
            )
        }

        func move(_ url: URL) -> Result<String, DiskExplorerTrashError> {
            DiskExplorerTrashPolicy.moveOutsideHomeItemToTrash(
                path: url.path, home: home.path, allowedRoots: allowedRoots,
                deniedSubtrees: deniedSubtrees, protectedRoots: protectedRoots
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: PrivilegedRemovabilityPolicy.firmlinkResolved(try makeRoot().path))
        let fake = root.appendingPathComponent("fakeroot")
        let fixture = Fixture(
            root: root,
            home: root.appendingPathComponent("home"),
            trash: root.appendingPathComponent("home/.Trash"),
            applications: fake.appendingPathComponent("Applications"),
            library: fake.appendingPathComponent("Library"),
            deniedApple: fake.appendingPathComponent("Library/Apple"),
            protectedDir: fake.appendingPathComponent("Library/Protected")
        )
        for dir in [fixture.trash, fixture.applications, fixture.deniedApple, fixture.protectedDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return fixture
    }

    @Test("Outside Home: items below an allowed root are .outsideHome; the root itself and prefix siblings are blocked")
    func outsideHomeAllowedRoots() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let app = fixture.applications.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let prefixSibling = fixture.root.appendingPathComponent("fakeroot/LibraryX/file")
        try FileManager.default.createDirectory(
            at: prefixSibling.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: prefixSibling.path, contents: Data())
        let elsewhere = fixture.root.appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: elsewhere.path, contents: Data())

        #expect(fixture.decision(app) == .outsideHome)
        #expect(fixture.decision(fixture.applications) != .outsideHome)
        #expect(fixture.decision(prefixSibling) != .outsideHome)
        #expect(fixture.decision(elsewhere) != .outsideHome)
    }

    @Test("Outside Home: denied subtrees, protected roots, and mount roots are blocked")
    func outsideHomeDeniedProtectedAndMounts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let deniedChild = fixture.deniedApple.appendingPathComponent("x")
        FileManager.default.createFile(atPath: deniedChild.path, contents: Data())
        let mount = fixture.applications.appendingPathComponent("mnt")
        let underMount = mount.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: underMount.path, contents: Data())
        let isMountRoot: (URL) -> Bool? = { url in
            PrivilegedRemovabilityPolicy.firmlinkResolved(url.path) == mount.path
        }

        #expect(fixture.decision(fixture.deniedApple) != .outsideHome)
        #expect(fixture.decision(deniedChild) != .outsideHome)
        #expect(fixture.decision(fixture.protectedDir) == .blocked(reason: "Protected: Test protected"))
        #expect(fixture.decision(mount, isMountRoot: isMountRoot) != .outsideHome)
        #expect(fixture.decision(underMount, isMountRoot: isMountRoot) != .outsideHome)
        #expect(fixture.decision(underMount, isMountRoot: { _ in nil }) != .outsideHome)
    }

    @Test("Home paths keep the canTrash rules under decision")
    func decisionHomeCases() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.home.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(fixture.decision(file) == .home)
        #expect(fixture.decision(fixture.home) != .home)
        #expect(fixture.decision(file, isMountRoot: { _ in nil }) != .home)
    }

    @Test("Default allow-list refuses system locations and allow-list roots lexically")
    func defaultAllowListLexical() {
        let blocked = [
            "/System/Library/x", "/usr/bin/x", "/bin/x", "/sbin/x", "/private/var/db/x",
            "/Library/Apple/x", "/library/apple/x", "/Applications", "/Users/someoneelse/x", "/LibraryX/x",
            "/System/Volumes/Data/Applications/x", "/Applications/../System/x", "/Library/APPLE/x",
        ]
        for path in blocked {
            #expect(DiskExplorerTrashPolicy.outsideHomeLexicalBlockReason(path) != nil, "\(path)")
            #expect(DiskExplorerTrashPolicy.decision(path: path, home: "/Users/nobody-here") != .outsideHome, "\(path)")
            #expect(DiskExplorerTrashPolicy.lexicalDecision(path: path, home: "/Users/nobody-here") != .outsideHome, "\(path)")
        }
        for path in ["/usr/local/x", "/Applications/Foo.app", "/Library/Caches/x", "/private/tmp/x", "/Users/Shared/x", "/tmp/x"] {
            #expect(DiskExplorerTrashPolicy.outsideHomeLexicalBlockReason(path) == nil, "\(path)")
            #expect(DiskExplorerTrashPolicy.lexicalDecision(path: path, home: "/Users/nobody-here") == .outsideHome, "\(path)")
        }
    }

    @Test("Every default denied subtree is blocked lexically")
    func defaultDeniedSubtreesAreBlockedLexically() {
        for root in DiskExplorerTrashPolicy.outsideHomeDeniedSubtrees {
            let path = "\(root)/x"
            #expect(DiskExplorerTrashPolicy.outsideHomeLexicalBlockReason(path) != nil, "\(path)")
        }
    }

    @Test("moveOutsideHomeItemToTrash moves files and folders into the Trash, numbering collisions")
    func moveOutsideHomeItems() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.applications.appendingPathComponent("notes.txt")
        let dir = fixture.applications.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        FileManager.default.createFile(atPath: fixture.trash.appendingPathComponent("notes.txt").path, contents: Data())

        #expect(fixture.move(file) == .success("notes 1.txt"))
        #expect(fixture.move(dir.deletingLastPathComponent()) == .success("Foo.app"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("notes 1.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("Foo.app/Contents").path))
    }

    @Test("moveOutsideHomeItemToTrash refuses a symlinked parent component and moves a symlink leaf as the link")
    func moveOutsideHomeSymlinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outsideDir = fixture.root.appendingPathComponent("outsideDir")
        let outsideFile = outsideDir.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data())
        let alias = fixture.applications.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outsideDir)

        guard case .failure = fixture.move(alias.appendingPathComponent("file")) else {
            Issue.record("a path through a symlinked parent was moved")
            return
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))

        let outsideTarget = fixture.root.appendingPathComponent("target")
        FileManager.default.createFile(atPath: outsideTarget.path, contents: Data())
        let link = fixture.applications.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideTarget)

        #expect(fixture.move(link) == .success("link"))
        #expect(FileManager.default.fileExists(atPath: outsideTarget.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.trash.appendingPathComponent("link").path
        )) != nil)
    }

    @Test("moveOutsideHomeItemToTrash refuses paths that aren't allowed and leaves them in place")
    func moveOutsideHomeRefusals() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let elsewhere = fixture.root.appendingPathComponent("elsewhere")
        let denied = fixture.deniedApple.appendingPathComponent("x")
        let homeFile = fixture.home.appendingPathComponent("file")
        for url in [elsewhere, denied, homeFile] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            guard case .failure = fixture.move(url) else {
                Issue.record("\(url.path) was moved")
                continue
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.trash.path))?.isEmpty == true)
    }
}
