import Foundation
import Testing
@testable import GargantuaCore

extension CzkawkaAdapterTests {
    @Test("invokes czkawka_cli once per configured category with scan roots")
    func invokesOncePerCategory() async throws {
        let runner = StubRunner(outputs: [:])
        let root = URL(fileURLWithPath: "/tmp/fake-root")
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/usr/local/bin/czkawka_cli"),
            categories: [.emptyFiles, .brokenSymlinks],
            scanRoots: [root],
            runner: runner
        )

        _ = try await adapter.scan(progress: nil)

        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].arguments == ["empty-files", "-d", root.path])
        #expect(runner.calls[1].arguments == ["symlinks", "-d", root.path])
        #expect(runner.calls.allSatisfy { $0.executable == "/usr/local/bin/czkawka_cli" })
    }

    @Test("multiple scan roots become repeated -d flags")
    func multipleScanRoots() async throws {
        let runner = StubRunner(outputs: [:])
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        let adapter = CzkawkaAdapter(
            binary: URL(fileURLWithPath: "/bin/czkawka"),
            categories: [.emptyFiles],
            scanRoots: [a, b],
            runner: runner
        )

        _ = try await adapter.scan(progress: nil)

        #expect(runner.calls.first?.arguments == ["empty-files", "-d", a.path, "-d", b.path])
    }
}
