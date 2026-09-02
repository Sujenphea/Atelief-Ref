//
//  CaptureTokenStoreTests.swift
//  AtelierRefsTests
//
//  099 · noted item — the capture token's storage, tested at last.
//
//  It had no tests, and the reason it had none is the reason it now takes a
//  `service:` parameter: every entry point was hard-coded to the production
//  Keychain item, so any test of it would have read, overwritten and deleted the
//  developer's REAL capture token — silently unpairing their browser extension —
//  and left an `AtelierCaptureToken` key behind in their standard defaults.
//
//  That is a bad trade for an untested type whose failure mode is quiet: the token
//  is minted once and read at every launch, and "capture stopped working after a
//  restart" is what a broken load looks like from outside.
//
//  Everything below runs against a service and a `UserDefaults` suite of its own,
//  named per-test with a UUID, and deletes what it made. Nothing here can touch
//  the item the app uses.
//

import Foundation
import Testing

@testable import AtelierRefs

@Suite("CaptureTokenStore (G6)")
struct CaptureTokenStoreTests {

    /// A service name no build ever uses, distinct per test so two running in
    /// parallel cannot fight over one Keychain item.
    private func testService() -> String {
        "so.atelier.refs.tests.capture-token.\(UUID().uuidString)"
    }

    /// A defaults suite of its own, so the legacy-migration test never writes to
    /// `UserDefaults.standard`.
    private func testDefaults() -> UserDefaults {
        UserDefaults(suiteName: "so.atelier.refs.tests.\(UUID().uuidString)")!
    }

    @Test("an empty store loads nothing")
    func emptyLoad() {
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults()) == nil)
    }

    @Test("a saved token loads back verbatim")
    func saveThenLoad() {
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }
        #expect(CaptureTokenStore.save("s3cr3t-token", service: service))
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults())
                    == "s3cr3t-token")
    }

    @Test("saving twice replaces rather than duplicating")
    func saveReplaces() {
        // `save` deletes before adding — without that, `SecItemAdd` returns
        // `errSecDuplicateItem` and the SECOND token is silently not stored, so a
        // regenerate would appear to work and the old token would keep working.
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }
        #expect(CaptureTokenStore.save("first", service: service))
        #expect(CaptureTokenStore.save("second", service: service))
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults()) == "second")
    }

    @Test("a legacy UserDefaults token migrates once, then the plist copy is gone")
    func legacyMigration() {
        let service = testService()
        let defaults = testDefaults()
        defer { CaptureTokenStore.delete(service: service) }
        defaults.set("legacy-token", forKey: CaptureTokenStore.legacyDefaultsKey)

        #expect(CaptureTokenStore.load(service: service, defaults: defaults) == "legacy-token")
        // The whole point of the migration: the secret must not be left sitting in
        // a cleartext plist beside the Keychain copy.
        #expect(defaults.string(forKey: CaptureTokenStore.legacyDefaultsKey) == nil)
        // And it is now in the Keychain, so a second load does not need the plist.
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults())
                    == "legacy-token")
    }

    @Test("the Keychain wins over a stale legacy value")
    func keychainBeatsLegacy() {
        // A half-finished migration (Keychain written, defaults removal failed)
        // must not resurrect the old token on the next launch.
        let service = testService()
        let defaults = testDefaults()
        defer { CaptureTokenStore.delete(service: service) }
        CaptureTokenStore.save("current", service: service)
        defaults.set("stale", forKey: CaptureTokenStore.legacyDefaultsKey)

        #expect(CaptureTokenStore.load(service: service, defaults: defaults) == "current")
        // The stale value is left alone rather than deleted — nothing migrated.
        #expect(defaults.string(forKey: CaptureTokenStore.legacyDefaultsKey) == "stale")
    }

    @Test("an empty legacy value is not a token")
    func emptyLegacyIgnored() {
        let service = testService()
        let defaults = testDefaults()
        defer { CaptureTokenStore.delete(service: service) }
        defaults.set("", forKey: CaptureTokenStore.legacyDefaultsKey)
        #expect(CaptureTokenStore.load(service: service, defaults: defaults) == nil)
    }

    @Test("two services do not see each other's token")
    func servicesAreIsolated() {
        // The property the whole parameter exists for, asserted rather than
        // assumed: if the service name were ignored, every test above would be
        // reading and writing the production item.
        let a = testService()
        let b = testService()
        defer { CaptureTokenStore.delete(service: a); CaptureTokenStore.delete(service: b) }
        CaptureTokenStore.save("token-a", service: a)
        #expect(CaptureTokenStore.load(service: b, defaults: testDefaults()) == nil)
        #expect(CaptureTokenStore.load(service: a, defaults: testDefaults()) == "token-a")
    }

    @Test("delete removes the item and is idempotent")
    func deleteIsIdempotent() {
        let service = testService()
        CaptureTokenStore.save("gone-soon", service: service)
        #expect(CaptureTokenStore.delete(service: service))
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults()) == nil)
        #expect(CaptureTokenStore.delete(service: service), "deleting nothing is not a failure")
    }

    @Test("the production service name is the one the app has always used")
    func productionNameUnchanged() {
        // Making the name a parameter must not change the name. A different
        // string here would orphan every existing user's token and mint a new one
        // at the next launch, unpairing their extension for no reason.
        #expect(CaptureTokenStore.productionService == "so.atelier.refs.capture-token")
        #expect(CaptureTokenStore.legacyDefaultsKey == "AtelierCaptureToken")
    }

    // MARK: - Off the main actor (099 · 22A)

    /// **The assertion this phase exists for.** `loadOrCreate` must not do its
    /// keychain work on the main thread.
    ///
    /// It is asserted directly rather than as a DURATION, which would be a bet on a
    /// loaded machine and would pass for the wrong reason on a fast one. The seam is
    /// the `defaults:` parameter the store already had: `load` calls
    /// `defaults.string(forKey:)` itself, so a `UserDefaults` subclass that records
    /// `Thread.isMainThread` reports the executor the store was ACTUALLY running on,
    /// at the moment it was doing the work — not the executor the test was on.
    ///
    /// **This test discriminates.** Delete `@concurrent` from `loadOrCreate` and it
    /// fails: the app target sets `SWIFT_APPROACHABLE_CONCURRENCY = YES`, so a plain
    /// `nonisolated async` function inherits its caller's isolation (SE-0461), this
    /// test function is main-actor-isolated by the target's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the store would run right
    /// here on the main thread. That is the whole bug, reproduced in one attribute.
    ///
    /// The keychain is empty for this service, so the load falls through to the
    /// legacy lookup, which is the call that gets recorded. The legacy value is real
    /// so the migration path runs too — a token that arrives off-main is the point.
    @Test("loadOrCreate does its keychain work off the main thread")
    func loadOrCreateRunsOffTheMainThread() async {
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }
        let defaults = ThreadRecordingDefaults(
            suiteName: "so.atelier.refs.tests.\(UUID().uuidString)")!
        defaults.set("legacy-off-main", forKey: CaptureTokenStore.legacyDefaultsKey)

        #expect(isOnMainThread(), "the test itself is main-actor isolated")
        let token = await CaptureTokenStore.loadOrCreate(
            service: service, defaults: .init(defaults))

        #expect(token == "legacy-off-main")
        #expect(defaults.sawMainThread == false,
                "loadOrCreate ran on the main thread — @concurrent is not doing its job")
    }

    /// The primitives are reachable from a nonisolated context at all.
    ///
    /// **Compiling is half of this assertion.** Before 22A these statics were
    /// implicitly `@MainActor` — not by annotation but by the target's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — and the body below would not
    /// have built: a `Task.detached` closure is nonisolated and cannot call a
    /// main-actor function synchronously at all. The runtime half confirms the
    /// detached task really was off the main thread, so the compile-time property is
    /// not vacuous.
    @Test("the keychain primitives are callable off the main actor")
    func primitivesAreReachableOffTheMainActor() async {
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }

        let result = await Task.detached { () -> (offMain: Bool, token: String?) in
            let offMain = !isOnMainThread()
            _ = CaptureTokenStore.save("off-main-token", service: service)
            // A suite of its own, built in here, so nothing crosses the boundary but
            // the service name (a `String`).
            let defaults = UserDefaults(
                suiteName: "so.atelier.refs.tests.\(UUID().uuidString)")!
            return (offMain, CaptureTokenStore.load(service: service, defaults: defaults))
        }.value

        #expect(result.offMain, "Task.detached ran on the main thread")
        #expect(result.token == "off-main-token")
    }

    // MARK: - The async entry points' behaviour

    @Test("loadOrCreate returns the already-stored token rather than minting")
    func loadOrCreateReturnsStored() async {
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }
        #expect(CaptureTokenStore.save("already-here", service: service))
        #expect(await CaptureTokenStore.loadOrCreate(
            service: service, defaults: .init(testDefaults())) == "already-here")
    }

    @Test("loadOrCreate mints and stores on first run, then keeps that token")
    func loadOrCreateMintsOnFirstRun() async {
        // The launch path's whole contract: the FIRST launch has to leave a token
        // behind, and the second has to find the same one. If the mint were not
        // stored, every launch would mint a fresh secret and the extension would be
        // unpaired by a restart — the quiet failure this type's tests exist for.
        let service = testService()
        let defaults = testDefaults()
        defer { CaptureTokenStore.delete(service: service) }

        let minted = await CaptureTokenStore.loadOrCreate(
            service: service, defaults: .init(defaults))
        #expect(!minted.isEmpty)
        // Stored, not merely returned — read back through the primitive.
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults()) == minted)
        // And a second launch does not mint a second one.
        #expect(await CaptureTokenStore.loadOrCreate(
            service: service, defaults: .init(defaults)) == minted)
    }

    @Test("loadOrCreate migrates a legacy UserDefaults token and clears the plist")
    func loadOrCreateMigratesLegacy() async {
        // G6 through the async path — the migration is the reason `load` touches
        // `UserDefaults` at all, and moving the call off the main actor must not
        // have moved it out of the launch path.
        let service = testService()
        let defaults = testDefaults()
        defer { CaptureTokenStore.delete(service: service) }
        defaults.set("legacy-async", forKey: CaptureTokenStore.legacyDefaultsKey)

        #expect(await CaptureTokenStore.loadOrCreate(
            service: service, defaults: .init(defaults)) == "legacy-async")
        #expect(defaults.string(forKey: CaptureTokenStore.legacyDefaultsKey) == nil)
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults())
                    == "legacy-async")
    }

    @Test("regenerate replaces the stored token with a different one")
    func regenerateReplaces() async {
        let service = testService()
        defer { CaptureTokenStore.delete(service: service) }
        #expect(CaptureTokenStore.save("the-old-one", service: service))

        let fresh = await CaptureTokenStore.regenerate(service: service)
        #expect(fresh != "the-old-one")
        #expect(!fresh.isEmpty)
        // Persisted, so the restarted endpoint binds to the new secret and the old
        // one stops working — which is what the Settings verb promises.
        #expect(CaptureTokenStore.load(service: service, defaults: testDefaults()) == fresh)
    }
}

/// A `UserDefaults` that remembers which thread its lookup ran on.
///
/// The one seam that can see inside ``CaptureTokenStore/loadOrCreate(service:defaults:)``
/// without the store growing a test-only hook: `load` calls `string(forKey:)` on the
/// instance it is handed, so this override runs in the store's own execution context.
/// Whether the CALLER is running on the main thread.
///
/// A one-line function for a reason the compiler insists on: `Thread.isMainThread` is
/// *unavailable from asynchronous contexts* ("Work intended for the main actor should be
/// marked with @MainActor"), so it cannot be read inline in an `async` test. Reading it
/// from a synchronous `nonisolated` function is both legal and exactly what is wanted —
/// a synchronous call runs on its caller's thread, so this reports the caller's thread
/// and not its own.
private nonisolated func isOnMainThread() -> Bool { Thread.isMainThread }

/// **`nonisolated` on the class is not decoration either.** The TEST target carries the
/// same `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the app target does, so without it
/// this subclass is implicitly `@MainActor` and the compiler rejects it outright:
/// *"main actor-isolated instance method 'string(forKey:)' has different actor isolation
/// from nonisolated overridden declaration"*. A probe for main-actor isolation that is
/// itself pinned to the main actor could only ever have reported `true`.
private nonisolated final class ThreadRecordingDefaults: UserDefaults {
    /// `nil` until the store looks something up; then whether that happened on the
    /// main thread. The main actor runs on the main thread, so `false` is proof the
    /// store was not on the main actor.
    ///
    /// `nonisolated(unsafe)` and not a lock: it is written once inside the awaited
    /// call and read only after that `await` has returned, so the suspension point is
    /// the ordering, and there is no second reader to race.
    nonisolated(unsafe) private(set) var sawMainThread: Bool?

    override func string(forKey defaultName: String) -> String? {
        if sawMainThread == nil { sawMainThread = isOnMainThread() }
        return super.string(forKey: defaultName)
    }
}
