import Foundation
import Testing
@testable import GargantuaCore

@Suite("LaunchdPlistParser")
struct LaunchdPlistParserTests {

    // MARK: - Required keys

    @Test("Missing Label throws .missingLabel")
    func missingLabelThrows() {
        let parser = DefaultLaunchdPlistParser()
        #expect(throws: LaunchdPlistParserError.missingLabel) {
            try parser.parse(dictionary: [
                "Program": "/usr/local/bin/foo",
            ])
        }
    }

    @Test("Empty Label throws .missingLabel")
    func emptyLabelThrows() {
        let parser = DefaultLaunchdPlistParser()
        #expect(throws: LaunchdPlistParserError.missingLabel) {
            try parser.parse(dictionary: [
                "Label": "",
            ])
        }
    }

    @Test("Minimal valid plist parses with defaults")
    func minimalPlist() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.example.helper",
        ])
        #expect(plist.label == "com.example.helper")
        #expect(plist.program == nil)
        #expect(plist.programArguments.isEmpty)
        #expect(plist.machServices.isEmpty)
        #expect(plist.sockets.isEmpty)
        #expect(plist.keepAlive == false)
        #expect(plist.runAtLoad == false)
        #expect(plist.startInterval == nil)
        #expect(plist.startCalendarInterval.isEmpty)
        #expect(plist.watchPaths.isEmpty)
        #expect(plist.queueDirectories.isEmpty)
        #expect(plist.disabled == false)
    }

    // MARK: - Real-world shapes

    @Test("Adobe-style plist with Program + RunAtLoad parses correctly")
    func adobeStyle() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.adobe.AdobeCreativeCloud",
            "Program": "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app/Contents/MacOS/Creative Cloud",
            "RunAtLoad": true,
            "KeepAlive": true,
        ])
        #expect(plist.label == "com.adobe.AdobeCreativeCloud")
        #expect(plist.program?.contains("Creative Cloud") == true)
        #expect(plist.runAtLoad == true)
        #expect(plist.keepAlive == true)
        #expect(plist.executablePath?.contains("Creative Cloud") == true)
    }

    @Test("Microsoft-style plist with ProgramArguments + MachServices")
    func microsoftStyle() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.microsoft.update.agent",
            "ProgramArguments": [
                "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant",
                "--check",
            ],
            "RunAtLoad": false,
            "StartInterval": 7200,
            "MachServices": [
                "com.microsoft.update.agent": true,
            ],
        ])
        #expect(plist.label == "com.microsoft.update.agent")
        #expect(plist.programArguments.count == 2)
        #expect(plist.programArguments[0].contains("Microsoft Update Assistant"))
        #expect(plist.startInterval == 7200)
        #expect(plist.machServices == ["com.microsoft.update.agent"])
        #expect(plist.executablePath == plist.programArguments[0])
    }

    @Test("Dropbox-style plist with WatchPaths and QueueDirectories")
    func dropboxStyle() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.dropbox.DropboxMacUpdate.agent",
            "ProgramArguments": ["/Library/DropboxHelperTools/DropboxHelperInstaller"],
            "WatchPaths": ["/Library/PrivilegedHelperTools/com.dropbox.dbx.cli"],
            "QueueDirectories": ["/var/db/dropbox-queue"],
        ])
        #expect(plist.watchPaths == ["/Library/PrivilegedHelperTools/com.dropbox.dbx.cli"])
        #expect(plist.queueDirectories == ["/var/db/dropbox-queue"])
    }

    @Test("1Password-style plist with KeepAlive conditions dict normalizes to true")
    func keepAliveConditionsDict() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.1password.1password",
            "ProgramArguments": ["/Applications/1Password.app/Contents/MacOS/1Password"],
            "KeepAlive": [
                "SuccessfulExit": false,
                "NetworkState": true,
            ],
        ])
        #expect(plist.keepAlive == true)
    }

    @Test("Empty KeepAlive conditions dict normalizes to false")
    func emptyKeepAliveDict() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.example.helper",
            "KeepAlive": [String: Any](),
        ])
        #expect(plist.keepAlive == false)
    }

    @Test("Docker-style plist with Sockets and Disabled")
    func dockerStyle() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.docker.helper",
            "Program": "/Library/PrivilegedHelperTools/com.docker.vmnetd",
            "Sockets": [
                "Listener": [
                    "SockServiceName": "com.docker.helper",
                ],
            ],
            "Disabled": true,
        ])
        #expect(plist.sockets == ["Listener"])
        #expect(plist.disabled == true)
    }

    // MARK: - StartCalendarInterval normalisation

    @Test("StartCalendarInterval as single dict normalizes to one-element array")
    func calendarIntervalSingleDict() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.example.daily",
            "StartCalendarInterval": [
                "Hour": 3,
                "Minute": 30,
            ],
        ])
        #expect(plist.startCalendarInterval.count == 1)
        #expect(plist.startCalendarInterval[0].hour == 3)
        #expect(plist.startCalendarInterval[0].minute == 30)
    }

    @Test("StartCalendarInterval as array of dicts is preserved")
    func calendarIntervalArray() throws {
        let plist = try DefaultLaunchdPlistParser().parse(dictionary: [
            "Label": "com.example.thrice",
            "StartCalendarInterval": [
                ["Hour": 0],
                ["Hour": 8],
                ["Hour": 16],
            ],
        ])
        #expect(plist.startCalendarInterval.count == 3)
        #expect(plist.startCalendarInterval.map { $0.hour } == [0, 8, 16])
    }

    // MARK: - Disk read

    @Test("Reading nonexistent file throws .unreadable")
    func unreadableFileThrows() {
        let parser = DefaultLaunchdPlistParser()
        let url = URL(fileURLWithPath: "/nonexistent/launchd-\(UUID().uuidString).plist")
        #expect(throws: (any Error).self) {
            try parser.parse(plistURL: url)
        }
    }

    @Test("Reading a real plist file off disk works end-to-end")
    func roundTripDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchdPlistParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("com.example.test.plist")
        let dict: [String: Any] = [
            "Label": "com.example.test",
            "ProgramArguments": ["/usr/local/bin/foo", "--watch"],
            "RunAtLoad": true,
            "StartInterval": 600,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)

        let plist = try DefaultLaunchdPlistParser().parse(plistURL: plistURL)
        #expect(plist.label == "com.example.test")
        #expect(plist.programArguments == ["/usr/local/bin/foo", "--watch"])
        #expect(plist.runAtLoad == true)
        #expect(plist.startInterval == 600)
    }

    @Test("Plist whose root is an array throws .rootNotDictionary")
    func nonDictionaryRoot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchdPlistParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("array-root.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["nope"],
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)

        #expect(throws: LaunchdPlistParserError.rootNotDictionary) {
            try DefaultLaunchdPlistParser().parse(plistURL: plistURL)
        }
    }
}
