//
//  ConfigContractTests.swift
//  AtelierRefsTests
//
//  052 · Distribution — config-regression guards (12A). These assert on shipping
//  configuration that has no other runtime test and that silently excludes users
//  or breaks updates when wrong. This file currently guards the deployment-target
//  floor (A0); the Sparkle feed/key guards join here when Sparkle lands (A3/A4).
//  (The entitlements + notarization/staple checks live in scripts/verify-release.sh
//  per 9A, since they need the *signed* artifact — CI builds run unsigned.)
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
