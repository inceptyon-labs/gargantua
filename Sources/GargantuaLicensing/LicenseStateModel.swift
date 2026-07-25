import Foundation
import Observation

@MainActor
@Observable
public final class LicenseStateModel {
    public static let shared = LicenseStateModel()

    public private(set) var state: LicenseState = .none

    private let gate: LicenseGate
    @ObservationIgnored private var revalidationTask: Task<Void, Never>?

    public init(gate: LicenseGate = .shared, revalidationInterval: Duration = .seconds(6 * 60 * 60)) {
        self.gate = gate
        // Set initial state from cache immediately (.task on a view that
        // initially resolves to EmptyView doesn't reliably fire), then keep
        // revalidating for as long as the app runs: each granted round-trip
        // re-extends the 14-day offline grace window, so an always-on Mac
        // never ages out of it while online.
        revalidationTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                await self?.revalidate()
                try? await Task.sleep(for: revalidationInterval)
                guard self != nil, !Task.isCancelled else { return }
            }
        }
    }

    deinit {
        revalidationTask?.cancel()
    }

    /// Fast: reads cache + trial clock, no network.
    public func refresh() async {
        state = await gate.currentState()
    }

    /// Background server check — extends offline grace, catches revocation.
    public func revalidate() async {
        await gate.revalidate()
        await refresh()
    }

    /// Paste-key activation. Network round-trip; updates state on success.
    public func activate(key: String) async -> Result<Void, PolarLicenseError> {
        let result = await gate.activate(key: key)
        await refresh()
        return result.map { _ in () }
    }

    @discardableResult
    public func deactivate() async -> Result<Void, PolarLicenseError> {
        let result = await gate.deactivate()
        await refresh()
        return result
    }
}
