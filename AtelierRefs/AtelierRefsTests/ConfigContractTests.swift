//
//  ConfigContractTests.swift
//  AtelierRefsTests
//
//  052 · Distribution — config-regression guards (12A). These assert on shipping
//  configuration that has no other runtime test and that silently excludes users
//  or breaks updates when wrong.
//
//  Both suites read the BUILT app bundle via `Bundle.main` rather than the repo's
//  source files. That is deliberate, not a shortcut: the AtelierRefsTests host is
//  the sandboxed AtelierRefs app, so a test process cannot read arbitrary repo
//  files (`Info.plist` / `.entitlements` off disk return POSIX EPERM — the sandbox
//  denies it). What the sandbox *does* allow is the app's own merged `Info.plist`,
//  which is exactly what 12A specifies ("the built app's Info.plist has SUFeedURL /
//  SUPublicEDKey"). The keys are merged in via GENERATE_INFOPLIST_FILE, so a build
//  that dropped them fails here.
//
//  Suites in this file:
//   • DeploymentTargetContractTests (A0) — LSMinimumSystemVersion ≤ floor. The built
//     value is exactly what MACOSX_DEPLOYMENT_TARGET produces, so a pbxproj bump
//     above the floor fails here. No separate pbxproj parse is added (DRY — this
//     already covers the 12A deployment-target clause).
//   • SparkleFeedKeyContractTests   (A4) — the built Info.plist declares the Sparkle
//     SUFeedURL / SUPublicEDKey keys (key PRESENCE, so every build carries them).
//
//  Deliberately NOT unit tests here (documented reason each):
//   • Entitlements snapshot (app-sandbox + network.server + Sparkle mach-lookup):
//     un-testable host-free in this target — the sandboxed host can't read the
//     source .entitlements, and the unsigned CI build embeds no readable
//     entitlements. It lives in scripts/verify-release.sh (9A, check 5), which reads
//     them from the *signed* binary. That was already the A0 author's decision.
//   • "SUFeedURL is a real non-placeholder URL" + "the appcast validates and its
//     EdDSA signature verifies": can't pass until a human sets real values/hosting,
//     so they gate *real releases* in verify-release.sh (checks 7–8), never a push.
//

import Foundation
import Testing

@Suite("Config contract: deployment target")
struct DeploymentTargetContractTests {

    /// The maximum acceptable `LSMinimumSystemVersion` the shipped app may declare.
    ///
    /// Lowering the deployment target below this is fine (it widens reach); raising
    /// it *above* the floor excludes users and must be a deliberate, reviewed change.
    /// This guard turns an accidental bump — e.g. re-introducing the old `26.5`
    /// placeholder — into a failing test rather than a silently narrower audience.
    static let floor = [26, 0]

    @Test("shipping LSMinimumSystemVersion does not regress above the agreed floor")
    func minimumSystemVersionWithinFloor() throws {
        // Hosted in the app (TEST_HOST), so `Bundle.main` is the app bundle whose
        // generated Info.plist carries LSMinimumSystemVersion from the build setting.
        let raw = try #require(
            Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String,
            "app Info.plist is missing LSMinimumSystemVersion"
        )
        let version = raw.split(separator: ".").map { Int($0) ?? 0 }
        let floorText = Self.floor.map(String.init).joined(separator: ".")
        #expect(
            Self.componentsAtMost(version, Self.floor),
            "LSMinimumSystemVersion \(raw) exceeds the agreed floor \(floorText)"
        )
    }

    /// Component-wise `lhs <= rhs`, treating missing trailing components as 0 so
    /// "26" and "26.0" compare equal. Explicit rather than leaning on a version type.
    static func componentsAtMost(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return true // all components equal
    }
}

// MARK: - Sparkle feed / key presence (A4)

@Suite("Config contract: Sparkle feed keys")
struct SparkleFeedKeyContractTests {

    /// Sparkle refuses to check for updates without a feed URL and public key, so
    /// their *presence* in the shipping Info.plist is load-bearing for auto-update.
    /// We assert only that the keys EXIST — the values are deliberate placeholders
    /// until a human sets the real host + EdDSA key, and the "non-placeholder" gate
    /// lives in scripts/verify-release.sh so it fails real releases, not every push
    /// (testing non-placeholder here would keep the suite perpetually red).
    ///
    /// Read from `Bundle.main` (the built app), like the deployment-target guard
    /// above: the AtelierRefsTests host is sandboxed and cannot read the repo's
    /// source Info.plist off disk, but it *can* read its own merged Info.plist —
    /// which is exactly what 12A means by "the built app's Info.plist".
    @Test("built Info.plist declares SUFeedURL and SUPublicEDKey")
    func sparkleKeysPresent() throws {
        let info = try #require(Bundle.main.infoDictionary, "app has no Info.plist dictionary")
        #expect(info["SUFeedURL"] != nil, "built Info.plist is missing the Sparkle SUFeedURL key")
        #expect(info["SUPublicEDKey"] != nil, "built Info.plist is missing the Sparkle SUPublicEDKey key")
    }
}
