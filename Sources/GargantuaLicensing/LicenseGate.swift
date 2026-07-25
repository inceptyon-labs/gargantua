import Foundation

public actor LicenseGate {
    public static let shared = LicenseGate.makeDefault()

    private let store: LicenseStore
    private let clock: TrialClock

    public init(store: LicenseStore, clock: TrialClock) {
        self.store = store
        self.clock = clock
    }

    public static func makeDefault() -> LicenseGate {
        LicenseGate(store: LicenseStore(), clock: TrialClock())
    }

    public func canExecuteDestructiveAction() async -> GateDecision {
        switch await currentState() {
        case .licensed:
            return .allowed
        case .trial(let days) where days > 0:
            return .allowed
        case .trial, .expired:
            return .blocked(reason: .trialExpired)
        case .none:
            return .blocked(reason: .noLicense)
        }
    }

    /// Reads only the local cache + trial clock — never blocks on the network.
    /// Background revalidation (see `revalidate`) keeps the cache fresh.
    public func currentState() async -> LicenseState {
        #if GARGANTUA_LICENSING
            if let receipt = store.loadCachedReceipt(), store.isCurrentlyValid(receipt) {
                return .licensed(
                    email: receipt.email ?? receipt.displayName,
                    name: receipt.name ?? "",
                    activatedAt: receipt.activatedAt
                )
            }
            let days = clock.daysRemaining()
            return days > 0 ? .trial(daysRemaining: days) : .expired
        #else
            return .licensed(
                email: "source-build@local",
                name: "Source Build",
                activatedAt: .distantPast
            )
        #endif
    }

    // MARK: - Mutations (network)

    public func activate(key: String) async -> Result<LicenseReceipt, PolarLicenseError> {
        do {
            return .success(try await store.activate(key: key))
        } catch let error as PolarLicenseError {
            return .failure(error)
        } catch LicenseStoreError.persistenceFailed(let detail) {
            return .failure(.receiptSaveFailed(detail))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Best-effort background refresh. Swallows network errors so offline grace
    /// keeps the cached state; only revocation / not-found clears the cache.
    public func revalidate() async {
        _ = try? await store.revalidate()
    }

    /// Releases this Mac's activation slot. Returns the outcome so the caller
    /// can tell the user — a silently swallowed failure leaves the slot
    /// consumed and the user believing it was freed, which is exactly how an
    /// activation orphans.
    @discardableResult
    public func deactivate() async -> Result<Void, PolarLicenseError> {
        do {
            try await store.deactivate()
            return .success(())
        } catch let error as PolarLicenseError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
