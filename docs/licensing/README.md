# Licensing

Gargantua is sold through **Polar.sh** (Merchant of Record). Source stays AGPL-3.0; the paid path is compiled in only when `GARGANTUA_LICENSING=1`.

## How it works

1. Customer buys at the Polar checkout link (`LicensePolarConfig.checkoutURL`).
2. Polar issues a license key (prefix `GARG`) shown on the confirmation page + emailed.
3. Customer pastes the key into **Settings → License → Activate** (or the unlock sheet when a gated action is blocked).
4. The app calls Polar's **public** customer-portal API to activate (binds the key to this Mac, max 3) and stores the receipt in the Keychain (`KeychainLicenseReceiptStorage`, service `com.gargantua.licensing`). A pre-Keychain `~/Library/Application Support/Gargantua/license.json` is migrated once on first launch and not trusted after that.
5. On launch the app revalidates in the background; the cached `granted` state is trusted for a 14-day offline grace window.

## Why Polar (not FastSpring)

FastSpring gated account activation behind a sales call (contact was on a month's vacation). Polar is self-serve and instant. The FastSpring/AquaticPrime work (including the discovery that Apple removed DSA from `SecKey`, killing FastSpring's CocoaFob preset on modern macOS) was removed once Polar shipped; it remains in git history if we ever revisit.

## Security posture

The activate / validate / deactivate endpoints are **public** (Polar docs: "can be safely used on a public client, like a desktop application"). The only identifier embedded in the binary is the `organization_id`, a public UUID. **No secret token ships in the app.**

## Config: `Sources/GargantuaLicensing/LicensePolarConfig.swift`

- `organizationID`: public UUID, `06a0b65b-785b-4970-bef8-8ebf6274f719`
- `apiBaseURL`: `https://api.polar.sh/v1` (swap to `sandbox-api.polar.sh/v1` for sandbox dev)
- `checkoutURL`: the hosted Polar checkout link (Buy button target)
- `validationGraceInterval`: 14 days

## Architecture

- `PolarLicenseClient`: `URLSession` client: `activate` / `validate` / `deactivate`. Maps HTTP 403 → `.activationLimitReached`, 404 → `.notFound`.
- `LicenseStore`: persists the receipt, brokers the client, owns the offline-grace logic. Sync cache reads (gate never blocks on network); background `revalidate` extends grace + catches revocation.
- `LicenseGate`: actor; `currentState()` reads cache + trial clock only. `#if GARGANTUA_LICENSING` switches source-build (always licensed) vs licensed behavior.
- `LicenseStateModel`: `@Observable` singleton the UI binds to; seeds from cache on init, then revalidates.
- `TrialClock`: 14-day trial before a license is required (UserDefaults-backed).

## Issuing a test key

Run a $0 checkout through the checkout link with a 100%-off discount, or use the Polar dashboard. The key works against the production API immediately. (Deactivate it afterward from Settings → License so it doesn't consume one of your 3 slots.)
