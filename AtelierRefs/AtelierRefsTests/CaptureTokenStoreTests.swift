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
}
