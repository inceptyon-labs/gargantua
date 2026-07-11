import Testing
@testable import GargantuaCore

@Suite("LaunchdRuntimeState display helpers")
struct LaunchdRuntimeStateTests {
    @Test("pid set renders Running with PID")
    func pidSet() {
        let state = LaunchdRuntimeState(isLoaded: true, pid: 5036, lastExitStatus: nil, disabledOverride: nil)
        #expect(state.runtimeDisplay == "Running (PID 5036)")
    }

    @Test("loaded with no pid renders Loaded")
    func loadedNoPid() {
        let state = LaunchdRuntimeState(isLoaded: true, pid: nil, lastExitStatus: nil, disabledOverride: nil)
        #expect(state.runtimeDisplay == "Loaded")
    }

    @Test("not loaded renders Not loaded")
    func notLoaded() {
        let state = LaunchdRuntimeState(isLoaded: false, pid: nil, lastExitStatus: nil, disabledOverride: nil)
        #expect(state.runtimeDisplay == "Not loaded")
    }

    @Test("all fields unknown renders nil")
    func allNil() {
        let state = LaunchdRuntimeState(isLoaded: nil, pid: nil, lastExitStatus: nil, disabledOverride: nil)
        #expect(state.runtimeDisplay == nil)
    }

    @Test("detail with state and pid renders capitalized state with PID")
    func detailStateAndPid() {
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "running", pid: 5036, lastExitStatus: nil)
        #expect(detail.runtimeDisplay == "Running (PID 5036)")
    }

    @Test("detail with state only renders capitalized state")
    func detailStateOnly() {
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: "waiting", pid: nil, lastExitStatus: nil)
        #expect(detail.runtimeDisplay == "Waiting")
    }

    @Test("detail without state falls back to the pid rule")
    func detailFallbackPid() {
        let detail = LaunchdRuntimeDetail(isLoaded: true, state: nil, pid: 42, lastExitStatus: nil)
        #expect(detail.runtimeDisplay == "Running (PID 42)")
    }

    @Test("detail without state or pid falls back to the isLoaded rule")
    func detailFallbackLoaded() {
        let loaded = LaunchdRuntimeDetail(isLoaded: true, state: nil, pid: nil, lastExitStatus: nil)
        #expect(loaded.runtimeDisplay == "Loaded")

        let notLoaded = LaunchdRuntimeDetail(isLoaded: false, state: nil, pid: nil, lastExitStatus: nil)
        #expect(notLoaded.runtimeDisplay == "Not loaded")
    }

    @Test("detail with every field unknown renders nil")
    func detailAllNil() {
        let detail = LaunchdRuntimeDetail(isLoaded: nil, state: nil, pid: nil, lastExitStatus: nil)
        #expect(detail.runtimeDisplay == nil)
    }
}
