//
//  SparkleUpdaterConfigTests.swift
//  AtelierRefsTests
//
//  052 · A3 — guards the fix for "The updater failed to start": Sparkle must only
//  boot when Info.plist carries a real feed + EdDSA key, never the `REPLACE…`
//  placeholders (an invalid SUPublicEDKey is what makes `startUpdater:` fail).
//

import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite struct SparkleUpdaterConfigTests {
    /// A syntactically valid Ed25519 public key: 32 zero bytes → 44 Base64 chars.
    static let validKey = Data(repeating: 0, count: 32).base64EncodedString()
    static let feed = "https://updates.example.com/atelierrefs/appcast.xml"

    @Test func realConfigIsUsable() {
        #expect(UpdaterController.hasUsableUpdateConfiguration(
            feedURL: Self.feed, publicEDKey: Self.validKey))
    }

    @Test func shippedPlaceholdersAreRejected() {
        // The exact strings A3 wrote into Info.plist.
        #expect(!UpdaterController.hasUsableUpdateConfiguration(
            feedURL: "https://REPLACE-ME.example.com/atelierrefs/appcast.xml",
            publicEDKey: "REPLACE_WITH_PUBLIC_ED_KEY_FROM_generate_keys"))
    }

    @Test func placeholderInEitherFieldIsRejected() {
        #expect(!UpdaterController.hasUsableUpdateConfiguration(
            feedURL: Self.feed, publicEDKey: "REPLACE_WITH_PUBLIC_ED_KEY_FROM_generate_keys"))
        #expect(!UpdaterController.hasUsableUpdateConfiguration(
            feedURL: "https://REPLACE-ME.example.com/appcast.xml", publicEDKey: Self.validKey))
    }

    @Test func missingOrEmptyFieldsAreRejected() {
        #expect(!UpdaterController.hasUsableUpdateConfiguration(feedURL: nil, publicEDKey: nil))
        #expect(!UpdaterController.hasUsableUpdateConfiguration(feedURL: Self.feed, publicEDKey: nil))
        #expect(!UpdaterController.hasUsableUpdateConfiguration(feedURL: nil, publicEDKey: Self.validKey))
        #expect(!UpdaterController.hasUsableUpdateConfiguration(feedURL: "", publicEDKey: Self.validKey))
        #expect(!UpdaterController.hasUsableUpdateConfiguration(feedURL: Self.feed, publicEDKey: ""))
    }

    @Test func malformedKeyIsRejected() {
        // Not Base64 at all.
        #expect(!UpdaterController.hasUsableUpdateConfiguration(
            feedURL: Self.feed, publicEDKey: "not-base64-!!!"))
        // Valid Base64 but the wrong length for an Ed25519 key (16 bytes, not 32).
        let shortKey = Data(repeating: 0, count: 16).base64EncodedString()
        #expect(!UpdaterController.hasUsableUpdateConfiguration(
            feedURL: Self.feed, publicEDKey: shortKey))
    }
}
