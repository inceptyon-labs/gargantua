import Foundation
import Testing
@testable import GargantuaCore

@Suite("PathStreamViewModel")
@MainActor
struct PathStreamViewModelTests {

    @Test("append adds event and updates aggregates for .match")
    func appendMatch() {
        let vm = PathStreamViewModel()
        vm.append(ScanProgressEvent(path: "/tmp/a", outcome: .match, bytes: 100))
        #expect(vm.events.count == 1)
        #expect(vm.matchCount == 1)
        #expect(vm.totalBytes == 100)
        #expect(vm.failureCount == 0)
    }

    @Test("append with .checked does not bump match/failure counts")
    func appendChecked() {
        let vm = PathStreamViewModel()
        vm.append(ScanProgressEvent(path: "/tmp/a", outcome: .checked))
        #expect(vm.events.count == 1)
        #expect(vm.matchCount == 0)
        #expect(vm.failureCount == 0)
    }

    @Test(".failed increments failure count")
    func appendFailure() {
        let vm = PathStreamViewModel()
        vm.append(ScanProgressEvent(path: "/tmp/a", outcome: .failed(reason: "boom")))
        #expect(vm.failureCount == 1)
        #expect(vm.matchCount == 0)
    }

    @Test("buffer caps at bufferCap; oldest drops first")
    func bufferCap() {
        let vm = PathStreamViewModel(bufferCap: 3)
        for i in 0..<5 {
            vm.append(ScanProgressEvent(path: "/tmp/\(i)", outcome: .checked))
        }
        #expect(vm.events.count == 3)
        #expect(vm.events.first?.path == "/tmp/2")
        #expect(vm.events.last?.path == "/tmp/4")
    }

    @Test("aggregates persist when events roll off the buffer")
    func aggregatesPersistAcrossRollOff() {
        let vm = PathStreamViewModel(bufferCap: 2)
        vm.append(ScanProgressEvent(path: "/a", outcome: .match, bytes: 50))
        vm.append(ScanProgressEvent(path: "/b", outcome: .match, bytes: 30))
        vm.append(ScanProgressEvent(path: "/c", outcome: .match, bytes: 20))
        #expect(vm.events.count == 2)
        #expect(vm.matchCount == 3)
        #expect(vm.totalBytes == 100)
    }

    @Test("clear resets buffer and aggregates")
    func clearResets() {
        let vm = PathStreamViewModel()
        vm.append(ScanProgressEvent(path: "/a", outcome: .match, bytes: 10))
        vm.append(ScanProgressEvent(path: "/b", outcome: .failed(reason: "x")))
        vm.clear()
        #expect(vm.events.isEmpty)
        #expect(vm.matchCount == 0)
        #expect(vm.failureCount == 0)
        #expect(vm.totalBytes == 0)
    }

    @Test("didEmit from nonisolated context forwards to main actor in order")
    func nonisolatedForwarding() async {
        let vm = PathStreamViewModel()
        // Mimic a scanner on a background task emitting multiple events.
        await Task.detached {
            for i in 0..<10 {
                vm.didEmit(ScanProgressEvent(path: "/tmp/\(i)", outcome: .checked))
            }
        }.value
        // Let main-actor Tasks drain.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.events.count == 10)
        #expect(vm.events.first?.path == "/tmp/0")
        #expect(vm.events.last?.path == "/tmp/9")
    }
}

@Suite("ScanProgressEvent instrumentation")
@MainActor
struct ScannerInstrumentationTests {
    @Test("RemnantScanner.plan emits .match for each remnant found")
    func remnantPlanEmits() async throws {
        let observer = PathStreamViewModel()
        // Create a temp directory with a known file to match a rule.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-instr-\(UUID().uuidString)", isDirectory: true)
        let supportDir = root.appendingPathComponent("Library/Application Support/MyApp", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let file = supportDir.appendingPathComponent("data.bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let rule = RemnantRule(
            id: "support",
            name: "Application Support",
            category: .supportFiles,
            pathTemplates: [supportDir.path],
            safety: .safe,
            confidence: 90,
            explanation: "Test",
            source: SourceAttribution(name: "Test")
        )
        let scanner = RemnantScanner(rules: [rule], scanRoots: [root], observer: observer)
        let app = AppInfo(
            bundleID: "com.example.MyApp",
            name: "MyApp",
            displayName: "MyApp",
            shortVersion: "1.0",
            bundleVersion: "1",
            bundlePath: "/tmp/MyApp.app",
            executablePath: "/tmp/MyApp.app/Contents/MacOS/MyApp",
            installDate: nil,
            lastUsedDate: nil,
            isRunning: false,
            isSystemApp: false,
            sizeOnDisk: 0,
            teamIdentifier: nil,
            signatureValid: false
        )
        _ = scanner.plan(for: app, includeAppBundle: false)

        // Allow main-actor drain for forwarded events.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(observer.matchCount >= 1)
        let matchedPaths = observer.events
            .filter { if case .match = $0.outcome { return true } else { return false } }
            .map(\.path)
        #expect(matchedPaths.contains(supportDir.path))
    }
}
