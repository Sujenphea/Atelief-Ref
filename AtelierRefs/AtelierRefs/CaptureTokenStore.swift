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

import Foundation
import Security

enum CaptureTokenStore {
    /// Legacy UserDefaults key (pre-Keychain). Read once for migration, then deleted.
    static let legacyDefaultsKey = "AtelierCaptureToken"

    /// The production Keychain service. The default for every parameter below;
    /// a test passes its own so it never touches this item.
    static let productionService = "so.atelier.refs.capture-token"

    private static let account = "capture-token"

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
