// AtelierRefs — a launch argument that keeps the capture endpoint out of a UI test
// (099 · 22A).
//
// **Why a UI test wants this.** The three smoke flows assert a window, a Settings
// scene and the sidebar's order. Not one of them speaks to the browser extension, so
// not one of them needs a listening socket or a pairing token — but starting the
// endpoint reads the token out of the login keychain, and the login keychain's ACL is
// bound to the reading binary's CODE SIGNATURE. `verify.sh`'s UI stage is the one
// stage that signs ad-hoc (it must — an unsigned XCTest runner is SIGKILLed, see 468),
// so every rebuild presents a new cdhash, macOS raises a `SecurityAgent` prompt, and
// an unattended `xcodebuild` has nobody to answer it. All three flows then fail on
// "process main thread busy for 30.0s" (470 diagnosed it).
//
// 22A's other half took that read off the main actor, so a stalled keychain can no
// longer hang the window — which is the production bug, and worth fixing on its own.
// It does not make the prompt stop appearing, and a flow that waits for a dialog no
// human will click is still a flow that times out. So the tests stop asking: an
// endpoint nothing asserts is an endpoint the suite should not be starting.
//
// **Three properties, deliberately.**
//
//   1. `#if DEBUG` — 099 · 8A's rule for launch arguments. A Release build does not
//      contain this type, and `IngestionModel`'s guard is compiled out with it, so
//      there is no argument a shipped app could be launched with that would silently
//      leave a user unpaired. The `App target (Release)` stage is what proves the
//      guard's other side still compiles.
//   2. The spelling matches ``FixtureLibrary/argument`` — a leading dash, words
//      hyphenated, the verb first. One convention, not a second one.
//   3. `isRequested(in:)` takes the argument vector, defaulted to the real one, the
//      way ``BakeoffAutorun/parse(arguments:)`` and
//      ``CanvasPinchBakeoff/parse(arguments:)`` already do here. A test can then say
//      what the predicate does without launching anything.
//
// **It is a bare flag, so at the test's call site it goes LAST.** `UserDefaults`
// parses launch arguments as `-key value` pairs, and a bare flag standing before
// `-AtelierDidCompleteOnboarding YES` would be read as that pair's KEY, swallowing the
// onboarding suppression and putting a first-run sheet over every flow.
// `SmokeUITests.launch()` carries that reasoning in full.

#if DEBUG

import Foundation

enum CaptureEndpointFlag {
    /// The launch argument that asks the app not to start the capture endpoint.
    static let argument = "-skip-capture-endpoint"

    /// Whether this launch was asked to skip the endpoint.
    ///
    /// `arguments` is a parameter with the real vector as its default so the rule is
    /// a pure function of its input — the `Debug/` convention here, and the only way
    /// a unit test can drive it: a test process's `CommandLine.arguments` belong to
    /// the xctest runner, not to the case being tested.
    static func isRequested(in arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(argument)
    }
}

#endif
