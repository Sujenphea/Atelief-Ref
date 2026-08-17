//
//  BakeoffAutorun.swift
//  AtelierRefs
//
//  037 — headless, launch-argument-driven automation for the bake-off.
//
//  The interactive harness needs a human to pick a mode and press Run. That
//  cannot produce the 037 matrix: 5 configurations x 2 scales x cold/warm x
//  repeats is ~30 launches, and a hand-driven run also cannot guarantee the
//  controlled variables (§3) — most importantly a FIXED window size, which sets
//  the visible cell count and is the independent variable being held constant.
//
//  So: one flag runs one configuration end to end, writes a self-describing
//  JSON file, and terminates with a meaningful exit code. The interactive path
//  is untouched — absent the flag, nothing here runs.
//
//      -grid-bakeoff -grid-bakeoff-autorun mode=appKit,wrappers=full,\
//          duration=10,repeats=3,out=/tmp/run.json
//
//  Provenance is not optional. A results file whose build configuration,
//  viewport, display refresh, or item count cannot be reconstructed FROM ITSELF
//  is useless — it cannot be checked against the §4 thresholds, and a Debug
//  number pasted into a discussion would silently damn SwiftUI. Every field
//  needed to re-derive the verdict is therefore written into the envelope.
//

import AppKit
import Foundation

// MARK: - Configuration

/// One scripted bake-off configuration, parsed from the launch arguments (037).
struct BakeoffAutorunConfig {
    static let launchArgument = "-grid-bakeoff-autorun"

    var mode: GridBakeoffMode
    var wrappers: GridBakeoffWrapperConfig
    /// Seconds per scroll ramp.
    var duration: TimeInterval
    /// How many ramps in this launch. Run 1 is COLD (fresh process, empty
    /// thumbnail cache), runs 2+ are WARM (037 §3.2). A cold sample therefore
    /// costs one launch, which is exactly why this is scriptable.
    var repeats: Int
    /// Where the JSON envelope is written.
    var outPath: String
    /// Which `NSScreen` to place the window on, by index into `NSScreen.screens`.
    ///
    /// Explicit rather than "wherever it lands": this machine has a ProMotion
    /// internal panel and a 60Hz external one, and the refresh period IS the
    /// threshold (037 §4). Defaults to 0 — the primary/menu-bar display — so a
    /// run is reproducible without the caller thinking about it, and the screen
    /// actually used is recorded in the export either way.
    var screenIndex: Int = 0

    /// Parse the flag's `key=value,key=value` payload.
    ///
    /// Returns `nil` when the flag is absent (the interactive path). Throws a
    /// message when the flag is present but unusable — a malformed automation
    /// run must fail loudly, never silently fall back to interactive and hang a
    /// script forever waiting for a file that is never written.
    static func parse(arguments: [String] = CommandLine.arguments) throws -> Self? {
        guard let flagIndex = arguments.firstIndex(of: launchArgument) else { return nil }
        let payloadIndex = arguments.index(after: flagIndex)
        guard payloadIndex < arguments.endIndex else {
            throw AutorunError("\(launchArgument) needs a key=value,… payload")
        }

        var fields: [String: String] = [:]
        for pair in arguments[payloadIndex].split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw AutorunError("malformed field '\(pair)' — expected key=value")
            }
            fields[String(parts[0]).trimmed] = String(parts[1]).trimmed
        }

        guard let modeRaw = fields["mode"] else { throw AutorunError("missing mode=") }
        guard let mode = GridBakeoffMode(rawValue: modeRaw) else {
            throw AutorunError(
                "unknown mode '\(modeRaw)' — expected one of "
                    + GridBakeoffMode.allCases.map(\.rawValue).joined(separator: ", "))
        }
        // Defaults to `full` because that is the production wrapper chain — the
        // real-world number. The AppKit mode ignores this by specification.
        let wrappersRaw = fields["wrappers"] ?? GridBakeoffWrapperConfig.full.rawValue
        guard let wrappers = GridBakeoffWrapperConfig(rawValue: wrappersRaw) else {
            throw AutorunError(
                "unknown wrappers '\(wrappersRaw)' — expected one of "
                    + GridBakeoffWrapperConfig.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard let outPath = fields["out"], !outPath.isEmpty else {
            throw AutorunError("missing out=<path>")
        }

        let duration = fields["duration"].flatMap(Double.init)
            ?? BakeoffScrollDriver.defaultDuration
        guard duration > 0 else { throw AutorunError("duration must be > 0") }
        let repeats = fields["repeats"].flatMap(Int.init) ?? 1
        guard repeats > 0 else { throw AutorunError("repeats must be > 0") }
        let screenIndex = fields["screen"].flatMap(Int.init) ?? 0
        guard screenIndex >= 0 else { throw AutorunError("screen must be >= 0") }

        return Self(
            mode: mode, wrappers: wrappers, duration: duration, repeats: repeats,
            outPath: outPath, screenIndex: screenIndex)
    }
}

/// A launch-argument problem, surfaced with a readable message.
struct AutorunError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

// MARK: - Exit codes

/// How an automated run ended. Distinct codes so a driving script can tell
/// "this configuration is slow" from "this configuration never ran" — the two
/// look identical in a results file that was never written.
enum BakeoffExitCode: Int32 {
    case success = 0
    /// The launch arguments could not be parsed.
    case badArguments = 64
    /// No collection named "Bakeoff" in the resolved library root.
    case noCollection = 65
    /// The mode never registered a scroll target, or the grid never laid out.
    case noScrollTarget = 66
    /// A ramp sampled zero frames — the run happened but measured nothing.
    case noFrames = 67
    /// The results file could not be written.
    case writeFailed = 68
}

// MARK: - The export envelope

/// A complete automated session: the controlled variables plus every ramp.
///
/// Deliberately a flat, self-describing record. 037 §3 lists seven variables any
/// one of which silently invalidates a run; each one that the process can
/// observe is written here, so the file can be audited without the shell command
/// that produced it.
struct BakeoffAutorunExport: Codable {
    /// Bumped if the shape changes, so old files stay interpretable.
    var schema = "grid-bakeoff/1"

    // §3.1 — the single most likely route to a wrong conclusion.
    var buildConfiguration: String = BuildConfiguration.current
    var isRelease: Bool = BuildConfiguration.isRelease

    var mode: GridBakeoffMode
    var wrappers: GridBakeoffWrapperConfig
    // §3.7 — same seeded collection. Recorded as the resolved override so a
    // 200-item file can never be mistaken for a 2000-item one.
    var libraryRoot: String
    var collectionName: String
    var itemCount: Int

    // §3.4 — identical scroll ramp.
    var durationSeconds: Double
    var repeats: Int

    // §3.3 — fixed window size. Both the window and the actual grid viewport,
    // because the viewport is what sets the visible cell count and it is derived
    // from the window minus the harness chrome.
    var windowWidth: Double
    var windowHeight: Double
    var viewportWidth: Double
    var viewportHeight: Double

    // §3.6 — refresh rate changes the frame budget and therefore the verdict.
    var screenName: String
    var screenRefreshHz: Double
    var refreshPeriodMs: Double
    var screenBackingScaleFactor: Double
    var screenWidth: Double
    var screenHeight: Double

    var machine: String
    var osVersion: String
    var startedAt: Date
    var runs: [Run]

    /// One scroll ramp.
    struct Run: Codable {
        var runIndex: Int
        /// §3.2 — `cold` on the first ramp of a fresh process (empty thumbnail
        /// cache), `warm` on every repeat after it. Spelled out rather than left
        /// implicit in `runIndex`, because the cold/warm split is the whole
        /// reason the AppKit number needs reading twice.
        var cacheState: String
        /// The §4 verdict, computed from `stats` at export time.
        var verdict: String
        var stats: FrameTimeStats
        var finishedAt: Date
        /// Every sampled frame interval, ms.
        ///
        /// Kept because the verdict is a function of the refresh period `P`, and
        /// `P` depends on which display the window landed on. With the raw
        /// intervals in the file, a run measured at 60Hz can be re-scored
        /// against a 120Hz budget without re-running the matrix — and any
        /// percentile in the export can be independently recomputed rather than
        /// taken on trust.
        var intervalsMs: [Double]
    }
}

// MARK: - Environment capture

/// The controlled variables this process can observe about itself (037 §3).
enum BakeoffEnvironment {
    /// The screen the window should sit on, per `screen=`, falling back to the
    /// primary display when the index does not exist.
    static func screen(at index: Int) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        return index < screens.count ? screens[index] : screens[0]
    }

    /// The library the app actually opened — the resolved `-library-root`
    /// override, or `default` when none was supplied.
    static var libraryRootDescription: String {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "-library-root"),
           arguments.index(after: index) < arguments.endIndex {
            return arguments[arguments.index(after: index)]
        }
        if let value = ProcessInfo.processInfo.environment["ATELIER_LIBRARY_ROOT"],
           !value.trimmed.isEmpty {
            return value
        }
        return "default"
    }

    static var machine: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        // `size` counts the NUL that `sysctlbyname` writes, so the text is
        // everything before the first one. The array form of `String(cString:)`
        // is deprecated for the ambiguity this line spells out instead.
        let text = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: text, as: UTF8.self)
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
