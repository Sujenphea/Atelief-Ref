// AtelierCapture — the companion's two bundle identifiers, spelled once (098 · finding 7).
//
// The phone app and its share extension each had a hand-spelled identifier: the app's in
// `AtelierRefsMobile/MobileIngest.swift` as `MobileLog.subsystem`, the extension's in
// `AtelierRefsShare/ShareLog.swift` as the fallback for `Bundle.main.bundleIdentifier`.
// Two literals, in two targets, describing one build setting — and the failure mode is the
// quiet one: rename `PRODUCT_BUNDLE_IDENTIFIER` and nothing breaks, nothing warns, and the
// two processes simply start logging under subsystems that no longer exist. A `log stream`
// filter written against the old name returns nothing, which reads as "the extension never
// ran" rather than as "you are watching the wrong subsystem".
//
// **Why a package and not a shared app file.** The two targets share no source. They share
// packages, and this is the one both of them link (the extension cannot link
// `AtelierIngestion`, and `AtelierLibraryPaths` is about the App Group container rather than
// about identity). It is the same shape as the App Group identifier one layer down, where
// `$(ATELIER_APP_GROUP)` feeds both the entitlement and the Info.plist key so the identifier
// a process ASKS for and the one it is GRANTED cannot disagree — except that a bundle
// identifier has no plist key an extension can read for its SIBLING, so the single spelling
// has to be a constant.
//
// **And the constant is checked against the build.** `CompanionBundleTests` reads
// `PRODUCT_BUNDLE_IDENTIFIER` back out of `project.pbxproj` and compares. A constant that
// claims to mirror a build setting and has no way to notice when it stops is the thing this
// file exists to remove, not a second instance of it.
//
// Only the extension reads this today; `MobileLog` adopts it in 098 · P6, which is the phase
// that may edit the phone app.

/// The companion's bundle identifiers — the phone app's, and its share extension's.
public enum CompanionBundle {
    /// The phone app (`project.pbxproj`, `PRODUCT_BUNDLE_IDENTIFIER` on `AtelierRefsMobile`).
    public static let app = "sujenphea.AtelierRefsMobile"

    /// The share extension. An app extension's identifier must be prefixed by its host
    /// app's, so this is a derivation rather than a second name — which is why it is
    /// written as one.
    public static let shareExtension = "\(app).Share"
}
