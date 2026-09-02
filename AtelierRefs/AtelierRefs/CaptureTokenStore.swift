//
//  CaptureTokenStore.swift
//  AtelierRefs
//
//  Keychain-backed storage for the long-lived capture token (G6). Migrates any
//  legacy UserDefaults value once, then deletes it so the secret is not left in
//  a cleartext plist.
//
//  **The service and the defaults are parameters** (099 · noted item). Every
//  entry point takes the Keychain service name and the `UserDefaults` it migrates
//  from, both defaulted to the production values, so the app is unchanged and a
//  test can drive load / save / migrate against a service and a suite that are
//  its own. Before this the type was untestable in the only way that matters: any
//  test of it would have read, overwritten and deleted the REAL capture token in
//  the developer's login keychain — silently unpairing their browser extension —
//  and left a `AtelierCaptureToken` key in their standard defaults. So there were
//  no tests, for a type whose failure mode is "capture stops working after a
//  restart and nothing says why".
//
//  **Every call here BLOCKS, and none of it may run on the main actor** (099 · 22A).
//  `SecItemCopyMatching` is a synchronous XPC round trip to `securityd`, and on the
//  file-based login keychain it can stop to put a dialog on the screen — a locked
//  keychain, or an ACL that does not recognise the calling binary's code signature.
//  The window server is waiting on the main thread while that happens, so the app
//  is not slow, it is HUNG. That is not hypothetical: it is what
//  `IngestionModel.bootstrap()` did at every launch until 22A, and what pinned the
//  UI stage's three smoke flows at "process main thread busy for 30.0s"
//  ([470](../../.change-log/470-the-second-cache-takes-the-same-seam.md) diagnosed
//  it; this file is half the fix).
//
//  **Two build settings, not one, put it on the main actor** — and the second is
//  the one that is easy to miss:
//
//    1. The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
//       so an unannotated type is *implicitly* `@MainActor`. These statics were
//       never `nonisolated`; they were main-actor-isolated by the build setting.
//       Hence the `nonisolated` on the enum below — without it, awaiting this type
//       from a background task would hop ONTO the main actor and block it there,
//       which is the opposite of the fix.
//    2. The app target also sets `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which
//       turns on `nonisolated(nonsending)`-by-default (SE-0461): a plain
//       `nonisolated async` function runs on its CALLER's actor. So `nonisolated`
//       plus `async` is still the main actor when the caller is. `@concurrent` is
//       what actually guarantees the global executor, and that is why
//       ``loadOrCreate(service:defaults:)`` and ``regenerate(service:)`` carry it.
//
//  The rule this leaves: the three primitives are synchronous and stay so, because
//  a test needs to drive them (a `defer` teardown cannot `await`) and because off
//  the main actor a blocking keychain call is exactly the right thing. The two
//  `@concurrent` entry points are the ONLY ones the app calls.
//

import AtelierServer
import Foundation
import Security

nonisolated enum CaptureTokenStore {
    /// Legacy UserDefaults key (pre-Keychain). Read once for migration, then deleted.
    static let legacyDefaultsKey = "AtelierCaptureToken"

    /// The production Keychain service. The default for every parameter below;
    /// a test passes its own so it never touches this item.
    static let productionService = "so.atelier.refs.capture-token"

    private static let account = "capture-token"

    /// A `UserDefaults` that is allowed to cross an isolation boundary.
    ///
    /// `UserDefaults` is documented thread-safe, and this app already relies on that
    /// in as many words — `IngestionModel.startCaptureEndpoint`'s `consentGranted`
    /// closure says "reads UserDefaults directly (thread-safe, no actor hop)". What
    /// it is NOT is `Sendable`: Foundation never marked it, so handing one to a
    /// `@concurrent` function is *"sending 'defaults' risks causing data races"* and
    /// the build stops.
    ///
    /// The alternatives were worse. A retroactive `extension UserDefaults:
    /// @unchecked Sendable` makes that claim for every `UserDefaults` in the module,
    /// on Foundation's behalf, from an app target. Taking a suite NAME instead of an
    /// instance would push construction inside the boundary and take the injection
    /// seam away — and that seam is what `loadOrCreateRunsOffTheMainThread` uses to
    /// see which thread the store ran on. So the unchecked claim is made here, once,
    /// about one value, next to the reason it is true.
    struct SendableDefaults: @unchecked Sendable {
        let wrapped: UserDefaults

        init(_ wrapped: UserDefaults) { self.wrapped = wrapped }

        /// The production default — the same `UserDefaults.standard` the synchronous
        /// primitives take.
        static let standard = SendableDefaults(.standard)
    }

    // MARK: - What the app calls (099 · 22A)

    /// The launch path's entry point: load the persisted token, minting and storing
    /// one on first run — **on the global executor, never on the caller's actor**.
    ///
    /// `@concurrent` is load-bearing and not decoration. Without it this function
    /// would inherit its caller's isolation (see the header's point 2), the caller
    /// is ``IngestionModel/startCaptureEndpoint(coordinator:services:)`` on the main
    /// actor, and `await`ing it would block the main thread on `securityd` exactly
    /// as the synchronous call it replaced did. `CaptureTokenStoreTests`
    /// `loadOrCreateRunsOffTheMainThread` asserts that, and fails if the attribute
    /// is removed.
    ///
    /// The behaviour is byte-for-byte what `IngestionModel.loadOrCreateCaptureToken()`
    /// did before it moved here: the same service, the same G6 legacy migration, the
    /// same `CaptureToken.generate()` on first run, the same token returned.
    @concurrent
    static func loadOrCreate(
        service: String = productionService,
        defaults: SendableDefaults = .standard
    ) async -> String {
        if let existing = load(service: service, defaults: defaults.wrapped) {
            return existing
        }
        let minted = CaptureToken.generate()
        _ = save(minted, service: service)
        return minted
    }

    /// Mint a fresh token and store it, replacing whatever is there — off the main
    /// actor, for the same reason ``loadOrCreate(service:defaults:)`` is.
    ///
    /// This is the Settings "Regenerate Token…" path
    /// (``IngestionModel/regenerateCaptureToken()``), which was doing its own
    /// blocking `save` on the main actor. That one is a user-initiated action rather
    /// than a launch, so it could not hang a window that had not opened yet — but it
    /// is the same blocking XPC call behind the same dialog, and there is no reason
    /// for the second-worst version of the bug to survive the fix for the worst.
    @concurrent
    @discardableResult
    static func regenerate(service: String = productionService) async -> String {
        let minted = CaptureToken.generate()
        _ = save(minted, service: service)
        return minted
    }

    // MARK: - The primitives (synchronous, blocking, off-main only)

    /// Load the persisted token, migrating from UserDefaults if needed. Returns
    /// `nil` when neither Keychain nor legacy storage has a value.
    static func load(
        service: String = productionService,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let keychain = readKeychain(service: service), !keychain.isEmpty {
            return keychain
        }
        if let legacy = defaults.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            _ = save(legacy, service: service)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return legacy
        }
        return nil
    }

    /// Persist `token` in the Keychain (replacing any prior item).
    @discardableResult
    static func save(_ token: String, service: String = productionService) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let query = itemQuery(service: service)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Remove the stored token.
    ///
    /// Exists for the tests' teardown, and says so rather than pretending to be a
    /// product affordance: nothing in the app deletes the token, it regenerates
    /// (``IngestionModel/regenerateCaptureToken()``), because an endpoint with no
    /// token is not a state the app has a UI for. A test that writes to a test
    /// service must be able to leave the keychain as it found it.
    @discardableResult
    static func delete(service: String = productionService) -> Bool {
        let status = SecItemDelete(itemQuery(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The identity of the one item this type owns, for a given service.
    private static func itemQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain(service: String) -> String? {
        var query = itemQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
