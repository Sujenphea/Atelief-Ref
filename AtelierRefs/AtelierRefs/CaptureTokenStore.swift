//
//  CaptureTokenStore.swift
//  AtelierRefs
//
//  Keychain-backed storage for the long-lived capture token (G6). Migrates any
//  legacy UserDefaults value once, then deletes it so the secret is not left in
//  a cleartext plist.
//

import Foundation
import Security

enum CaptureTokenStore {
    /// Legacy UserDefaults key (pre-Keychain). Read once for migration, then deleted.
    static let legacyDefaultsKey = "AtelierCaptureToken"

    private static let service = "so.atelier.refs.capture-token"
    private static let account = "capture-token"

    /// Load the persisted token, migrating from UserDefaults if needed. Returns
    /// `nil` when neither Keychain nor legacy storage has a value.
    static func load() -> String? {
        if let keychain = readKeychain(), !keychain.isEmpty {
            return keychain
        }
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            _ = save(legacy)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return legacy
        }
        return nil
    }

    /// Persist `token` in the Keychain (replacing any prior item).
    @discardableResult
    static func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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
