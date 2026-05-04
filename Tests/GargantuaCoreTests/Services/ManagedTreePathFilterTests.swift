import Testing
import Foundation
@testable import GargantuaCore

@Suite("ManagedTreePathFilter.isManaged")
struct ManagedTreePathFilterTests {

    @Test("Personal-document paths are NOT managed")
    func personalPaths() {
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Documents/notes.md"))
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Pictures/IMG_001.jpg"))
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Downloads/report.pdf"))
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Desktop/script.sh"))
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Movies/clip.mov"))
    }

    @Test("node_modules subtree is managed at any depth")
    func nodeModules() {
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Development/proj/node_modules/typescript/lib/typescript.js"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/work/a/b/c/node_modules/foo/bar.js"))
    }

    @Test("Common dependency directories are managed")
    func dependencyTrees() {
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/.git/objects/00/abc"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/Pods/AFNetworking/source.m"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/vendor/gems/rake-13.0/lib/rake.rb"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/.cargo/registry/src/foo/lib.rs"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/__pycache__/foo.cpython-311.pyc"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/.venv/lib/python3.11/site.py"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/bower_components/jquery/jquery.js"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/Carthage/Build/iOS/Foo.framework/Foo"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/.swiftpm/configuration/registries.json"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/.gradle/caches/modules-2/files-2.1/foo.jar"))
    }

    @Test("Bundle extensions mark interior contents as managed")
    func bundles() {
        #expect(ManagedTreePathFilter.isManaged("/Applications/Firefox.app/Contents/MacOS/firefox"))
        #expect(ManagedTreePathFilter.isManaged("/System/Library/Frameworks/Foundation.framework/Foundation"))
        #expect(ManagedTreePathFilter.isManaged("/Library/Extensions/SomeKext.kext/Contents/Info.plist"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Photos/Vacation.photoslibrary/originals/1/foo.jpg"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/build/Foo.dSYM/Contents/Info.plist"))
        #expect(ManagedTreePathFilter.isManaged("/installer/Foo.pkg/Payload/contents"))
    }

    @Test("Library/Caches and Xcode developer paths are managed (no home given)")
    func cachePathsAbsolute() {
        // Even without a home, these match via substring rules.
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Caches/com.apple.Safari/foo.cache"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Developer/Xcode/DerivedData/Foo-abc/Build/Products/Debug/Foo.app/Contents/MacOS/Foo"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Developer/CoreSimulator/Devices/DEAD-BEEF/data/Library/Caches/foo"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Logs/foo.log"))
    }

    @Test("Entire ~/Library/ tree is managed when home is given")
    func userLibraryTree() {
        let home = URL(fileURLWithPath: "/Users/jane")
        // All the dominant duplicate sources on a real Mac:
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Containers/com.foo.bar/Data/Library/Resources/icon.png", homeDirectory: home))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Group Containers/group.foo/shared.json", homeDirectory: home))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Mail/V10/account/INBOX.mbox/data/foo.emlx", homeDirectory: home))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Mobile Documents/com~apple~CloudDocs/notes.txt", homeDirectory: home))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Application Support/Adobe/Common/Plug-ins/foo.bundle", homeDirectory: home))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/Preferences/com.foo.plist", homeDirectory: home))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Library/CloudStorage/Dropbox/foo.pdf", homeDirectory: home))
    }

    @Test("~/.Trash is managed when home is given")
    func trash() {
        let home = URL(fileURLWithPath: "/Users/jane")
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/.Trash/old.zip", homeDirectory: home))
    }

    @Test("Absolute system roots are managed even without home")
    func absoluteSystemRoots() {
        #expect(ManagedTreePathFilter.isManaged("/System/Library/Frameworks/AppKit.framework/AppKit"))
        #expect(ManagedTreePathFilter.isManaged("/Library/Application Support/Adobe/foo.dat"))
        #expect(ManagedTreePathFilter.isManaged("/private/var/folders/xx/yy/T/some.tmp"))
        #expect(ManagedTreePathFilter.isManaged("/var/log/system.log"))
        #expect(ManagedTreePathFilter.isManaged("/usr/local/share/foo.txt"))
        #expect(ManagedTreePathFilter.isManaged("/opt/homebrew/share/zsh/foo.txt"))
        #expect(ManagedTreePathFilter.isManaged("/Applications/Safari.app/Contents/Resources/icon.png"))
    }

    @Test("User-named 'library' folder under Documents is NOT system-managed")
    func userLibraryNotConfusedWithSystem() {
        let home = URL(fileURLWithPath: "/Users/jane")
        // ~/Documents/library/ is the user's choice of folder name — not the
        // ~/Library/ tree. Must not be filtered.
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Documents/projects/library/utils.swift", homeDirectory: home))
    }

    @Test("Case is ignored on path components and extensions")
    func caseInsensitive() {
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/Node_Modules/foo/bar.js"))
        #expect(ManagedTreePathFilter.isManaged("/Applications/SomeApp.APP/Contents/MacOS/x"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/PODS/X/y.m"))
    }

    @Test("Substring-only matches don't trigger directory-name rule")
    func substringSafety() {
        // 'mynode_modules' is a single component containing 'node_modules' as
        // a substring — must NOT match the directory-name rule.
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Documents/mynode_modules-notes.md"))
        // 'apps' isn't an extension or directory we manage.
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Documents/apps/list.txt"))
    }

    @Test("Foundry/Forge lib/<hyphenated-package>/ is managed")
    func foundryLibHyphenated() {
        // Mirrors the cross-project Foundry duplicates from the user's
        // screenshot — openzeppelin-contracts vendored into two separate
        // crypto projects.
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Development/ethdecoy/lib/openzeppelin-contracts/test/token/ERC721/extensions/ERC721Consecutive.test.js"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Development/xenodex/contracts/lib/openzeppelin-contracts/contracts/governance/extensions/GovernorCountingOverridable.sol"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Development/myproj/lib/forge-std/src/Test.sol"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/proj/lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol"))
    }

    @Test("Forge no-hyphen libs (solmate, solady) are managed via known-name list")
    func foundryLibKnownNames() {
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Development/myproj/lib/solmate/src/tokens/ERC20.sol"))
        #expect(ManagedTreePathFilter.isManaged("/Users/jane/Development/myproj/lib/solady/src/utils/SafeTransferLib.sol"))
    }

    @Test("User's own lib/<plain-name>/ is NOT managed")
    func userLibPlain() {
        // Folder named lib/ with a non-hyphenated child — likely user code.
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Documents/myproject/lib/utils/helpers.swift"))
        #expect(!ManagedTreePathFilter.isManaged("/Users/jane/Documents/myproject/src/lib/parser.rs"))
    }
}
