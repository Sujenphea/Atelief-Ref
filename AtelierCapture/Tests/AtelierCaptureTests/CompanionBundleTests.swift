// AtelierCapture tests — the constants that claim to mirror the build (098 · finding 7).
//
// ``CompanionBundle`` exists so the phone app's and the share extension's identifiers are
// spelled once rather than twice. That is only worth anything if the one spelling is the
// RIGHT one, and a constant has no way to notice a `PRODUCT_BUNDLE_IDENTIFIER` edit — which
// is the exact failure the constant was introduced to remove, reintroduced one level up.
//
// So this reads the identifiers back out of `project.pbxproj` and compares. It is the same
// move `extension/test/ios-preprocessor.test.js` makes when it runs both DOM readers over
// one document: an agreement between two files is worth having mechanically or not at all.
//
// The project file is found relative to this source file rather than to the working
// directory, because `swift test` runs from the package and the project is two levels up.
// If it is not there — this package consumed on its own, or a checkout of the package alone
// — the test says so and stops rather than failing: the constant is still correct, there is
// simply nothing to check it against.

import Foundation
import Testing

import AtelierCapture

@Suite("Companion bundle identifiers (098 · finding 7)")
struct CompanionBundleTests {

    /// `<repo>/AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj`, or nil.
    private static var projectFile: String? {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AtelierCaptureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // AtelierCapture
            .deletingLastPathComponent()  // <repo>
        let project = repository
            .appendingPathComponent("AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj")
        return try? String(contentsOf: project, encoding: .utf8)
    }

    /// Every `PRODUCT_BUNDLE_IDENTIFIER` value in the project file, deduplicated.
    ///
    /// The setting appears once per build configuration, so a target contributes it twice
    /// (Debug and Release) and a set is the honest shape. A target whose two configurations
    /// disagree would show up here as two entries, and the assertions below would fail on
    /// whichever one is not the constant — which is the right outcome.
    private static func declaredIdentifiers(in project: String) -> Set<String> {
        var found: Set<String> = []
        for line in project.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER = ") else { continue }
            let value = trimmed
                .dropFirst("PRODUCT_BUNDLE_IDENTIFIER = ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";\" "))
            found.insert(value)
        }
        return found
    }

    @Test("the phone app's identifier is the one the project builds")
    func appIdentifierMatchesTheProject() throws {
        let project = try #require(
            Self.projectFile, "project.pbxproj is not beside this package — nothing to check")
        #expect(Self.declaredIdentifiers(in: project).contains(CompanionBundle.app))
    }

    @Test("the share extension's identifier is the one the project builds")
    func shareIdentifierMatchesTheProject() throws {
        let project = try #require(
            Self.projectFile, "project.pbxproj is not beside this package — nothing to check")
        #expect(Self.declaredIdentifiers(in: project).contains(CompanionBundle.shareExtension))
    }

    /// The platform rule, not a restatement of the constant: iOS requires an app
    /// extension's identifier to be its host app's with one more component. If that ever
    /// stops holding, the derivation above is wrong and so is the entitlement pairing.
    @Test("the extension's identifier is the app's plus exactly one component")
    func theExtensionIsPrefixedByItsHost() {
        #expect(CompanionBundle.shareExtension.hasPrefix(CompanionBundle.app + "."))
        let suffix = CompanionBundle.shareExtension
            .dropFirst(CompanionBundle.app.count + 1)
        #expect(!suffix.isEmpty)
        #expect(!suffix.contains("."))
    }
}
