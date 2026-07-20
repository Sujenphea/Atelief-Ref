//
//  GridBakeoffWindow.swift
//  AtelierRefs
//
//  037 — the bake-off shell: pick a mode, run the scripted scroll, read the
//  numbers, export them.
//
//  Opened ONLY under the `-grid-bakeoff` launch argument, in its own plain
//  `NSWindow` created by ``GridBakeoffAppDelegate``. Deliberately not a SwiftUI
//  `Scene`: a scene would have to be declared in `AtelierRefsApp.swift` and
//  reach the shared `IngestionModel`, which would let a bake-off run mutate the
//  real library's loaded collection. This window owns its OWN model instead, so
//  a measurement can never disturb the app it is measuring — and the whole
//  spike deletes by removing this folder plus one line.
//
//  Pair it with `-library-root` to point at a throwaway 2000-item library
//  (`LibraryLocation.resolvedRoot()` already honours that argument — it exists
//  for exactly this).
//

import AppKit
import AtelierCore
import Combine
import SwiftUI

// MARK: - Launch

/// Opens the bake-off window when `-grid-bakeoff` is present (037).
///
/// An `NSApplicationDelegateAdaptor` is the least invasive hook available: it
/// costs `AtelierRefsApp` a single additive line and needs no change to
/// `ContentView` or any grid code.
final class GridBakeoffAppDelegate: NSObject, NSApplicationDelegate {
    static let launchArgument = "-grid-bakeoff"

    /// The window's content size, in points. A CONSTANT, not a default: window
    /// size sets the visible cell count, which 037 §3.3 requires held identical
    /// across every mode. A run at a different size is not comparable to the
    /// rest of the matrix, so the automated path also drops `.resizable`.
    static let contentSize = NSSize(width: 1100, height: 820)

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains(Self.launchArgument) else { return }

        // Parse before building anything: a malformed automation payload must
        // fail immediately and visibly rather than silently opening an
        // interactive window a script will wait on forever.
        let autorun: BakeoffAutorunConfig?
        do {
            autorun = try BakeoffAutorunConfig.parse()
        } catch {
            FileHandle.standardError.write(
                Data("grid-bakeoff: \(error)\n".utf8))
            exit(BakeoffExitCode.badArguments.rawValue)
        }

        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        // Interactive use keeps the resize handle; an automated run must not be
        // resizable, so nothing (a restored frame, a tiling manager, a stray
        // click) can change the controlled variable mid-matrix.
        if autorun == nil { styleMask.insert(.resizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: styleMask, backing: .buffered, defer: false)
        window.title = "Grid Bake-off"
        // Never restore a previous frame — the saved size of an earlier session
        // would silently override the controlled window size.
        window.setContentSize(Self.contentSize)
        window.contentView = NSHostingView(rootView: GridBakeoffView(autorun: autorun))
        place(window, on: BakeoffEnvironment.screen(at: autorun?.screenIndex ?? 0))
        window.makeKeyAndOrderFront(nil)
        // Frontmost and unoccluded: a background or covered window has its
        // display link throttled by the window server, which would measure the
        // throttle rather than the grid.
        NSApp.activate(ignoringOtherApps: true)
        // Held so ARC doesn't close the window the moment this scope exits.
        self.window = window
    }

    /// Pin the window to a KNOWN screen rather than wherever `center()` lands it.
    ///
    /// Load-bearing on this machine specifically: a ProMotion internal panel and
    /// a 60Hz external one give two different refresh periods `P`, and `P` is
    /// the 037 §4 threshold. Which screen the window used is recorded in the
    /// export, so a run placed on the wrong one is detectable rather than
    /// invisible.
    private func place(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { window.center(); return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2))
    }
}

// MARK: - Results

/// One completed run — a mode plus its statistics (037). `Codable` so a session
/// exports as JSON and runs from different machines/branches can be diffed.
struct GridBakeoffResult: Identifiable, Codable {
    var id = UUID()
    var mode: GridBakeoffMode
    /// Which wrapper configuration produced this number (037 §2) — without it a
    /// `full` and a `stripped` run are indistinguishable in the export and the
    /// comparison is meaningless.
    var wrappers: GridBakeoffWrapperConfig
    /// Run 1 is COLD (fresh launch, empty thumbnail cache), run 2+ on the same
    /// mode+config are WARM (037 §3.2). Cold exercises the decode path; warm
    /// isolates layout/render. Both are reported.
    var runIndex: Int
    var itemCount: Int
    var durationSeconds: Double
    /// Recorded because window size sets the visible cell count — the
    /// independent variable 037 §3.3 requires held constant across modes.
    var viewportHeight: Double
    var stats: FrameTimeStats
    /// 037 §3.1: SwiftUI body evaluation and `ForEach` diffing are dramatically
    /// slower unoptimised, so a Debug measurement would unfairly damn SwiftUI —
    /// the single most likely way to reach a wrong conclusion. Stamped into
    /// every result so a Debug run can never be mistaken for a verdict.
    var buildConfiguration: String = BuildConfiguration.current
    var timestamp: Date = .now
}

/// Whether this binary was optimised (037 §3.1).
enum BuildConfiguration {
    static var current: String {
        #if DEBUG
        return "DEBUG — NOT VALID FOR A VERDICT"
        #else
        return "RELEASE"
        #endif
    }

    static var isRelease: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

// MARK: - The window

struct GridBakeoffView: View {
    /// The bake-off's OWN model (see the file header) — never the app's.
    @StateObject private var model = IngestionModel()

    @State private var mode: GridBakeoffMode = .swiftUIWindowed
    @State private var wrappers: GridBakeoffWrapperConfig = .full
    @State private var recorder = FrameTimeRecorder()
    @State private var driver = BakeoffScrollDriver()
    /// The live grid's scroll handle, published by the selected mode through
    /// `GridBakeoffContext.registerScrollTarget`. `nil` means the mode is a
    /// placeholder (or hasn't laid out yet) and Run must stay disabled.
    @State private var scrollTarget: BakeoffScrollTarget?
    @State private var results: [GridBakeoffResult] = []
    @State private var isRunning = false
    @State private var duration: TimeInterval = BakeoffScrollDriver.defaultDuration
    @State private var status = "Loading the Bakeoff collection…"
    /// The grid pane's measured size, recorded into the export as the viewport
    /// (037 §3.3). Taken from the pane rather than the window because the pane
    /// is what the cells lay out in — the window also contains the chrome.
    @State private var gridPaneSize: CGSize = .zero
    /// Per-run raw frame intervals, parallel to `results` — exported so any
    /// percentile or `P`-relative count can be recomputed after the fact.
    @State private var rawIntervals: [[Double]] = []
    /// Where the envelope actually landed — may differ from the requested path,
    /// see `writeExport`.
    @State private var exportedPath = ""

    /// Non-`nil` when this process was launched to run one configuration
    /// unattended and exit. `nil` is the interactive path, unchanged.
    private let autorun: BakeoffAutorunConfig?

    init(autorun: BakeoffAutorunConfig? = nil) {
        self.autorun = autorun
        // Seed the pickers from the configuration so the requested grid is the
        // one that gets built — setting them after the first body pass would
        // measure a mode switch on the first ramp.
        _mode = State(initialValue: autorun?.mode ?? .swiftUIWindowed)
        _wrappers = State(initialValue: autorun?.wrappers ?? .full)
        _duration = State(initialValue: autorun?.duration ?? BakeoffScrollDriver.defaultDuration)
    }

    /// Matches `CollectionView`'s constants so the bake-off lays out the same
    /// geometry the app does.
    private static let spacing: CGFloat = 8
    private static let topInset: CGFloat = 4
    /// The collection the bake-off measures, by name.
    private static let collectionName = "Bakeoff"

    var body: some View {
        VStack(spacing: 0) {
            // 037 §3.1 — an unoptimised build makes SwiftUI look far worse than
            // it is, and is the single most likely route to a wrong conclusion.
            // Impossible to miss rather than a footnote.
            if !BuildConfiguration.isRelease {
                Label(
                    "DEBUG build — numbers are NOT valid for a verdict. "
                        + "Re-run with a Release build.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.yellow.opacity(0.25))
            }
            controls
            Divider()
            gridPane
            Divider()
            resultsPane
        }
        // Hosts the NSView the recorder vends its CADisplayLink from. Behind
        // everything and hit-transparent, so it changes nothing it measures.
        .background(BakeoffDisplayLinkHost(recorder: recorder))
        .task {
            await loadBakeoffCollection()
            if let autorun { await runAutomated(autorun) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(GridBakeoffMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)
            // Switching modes tears down the previous grid, so its target is
            // stale — drop it and wait for the new grid to register.
            .onChange(of: mode) { _, _ in scrollTarget = nil }
            .disabled(isRunning)

            // 037 §2 — the control that keeps SwiftUI-vs-AppKit honest.
            Picker("Wrappers", selection: $wrappers) {
                ForEach(GridBakeoffWrapperConfig.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .onChange(of: wrappers) { _, _ in scrollTarget = nil }
            .disabled(isRunning)

            HStack(spacing: 4) {
                Text("Duration")
                TextField("", value: $duration, format: .number.precision(.fractionLength(0)))
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                Text("s")
            }
            .disabled(isRunning)

            Button(isRunning ? "Running…" : "Run") { Task { await run() } }
                .keyboardShortcut(.return)
                .disabled(isRunning || scrollTarget == nil || model.items.isEmpty)

            Spacer()
            Text(status).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: Grid

    /// The selected mode's grid. The `switch` IS the plug-in seam — each case
    /// names one struct in one file, so three agents never touch the same code.
    @ViewBuilder
    private var gridPane: some View {
        let context = GridBakeoffContext(
            items: model.items,
            density: .default,
            spacing: Self.spacing,
            topInset: Self.topInset,
            wrappers: wrappers,
            thumbnailURL: { model.thumbnailURL(for: $0) },
            blobURL: { model.blobURL(for: $0) },
            registerScrollTarget: { scrollTarget = $0 })

        Group {
            switch mode {
            case .swiftUIWindowed:
                SwiftUIWindowedBakeoffGrid(context: context)
            case .swiftUIEquatable:
                SwiftUIEquatableBakeoffGrid(context: context)
            case .appKit:
                AppKitBakeoffGrid(context: context)
            }
        }
        // A fresh identity per mode+config so switching fully tears the previous
        // grid down. Without it SwiftUI could reuse state across two
        // structurally similar grids and the second run would measure a warm
        // layout the first never had.
        // The item count is part of the identity, not decoration. Both SwiftUI
        // modes memoize their masonry layout through `MasonryLayoutCache` under a
        // CONSTANT version (correct — the item set is fixed for a run), so a grid
        // that first laid out while the collection was still loading caches a
        // ZERO-height layout and never recomputes: `contentHeight` stays at the
        // viewport, the scroll target has no travel, and the run reports "no
        // scroll target" with nothing visibly wrong. Interactive use hides this
        // because switching the picker after the load already forces a new
        // identity; an automated launch does not. Rebuilding when the items
        // arrive is the fix.
        .id("\(mode.rawValue)-\(wrappers.rawValue)-\(model.items.count)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Hit-transparent and drawing nothing — it only reports the viewport
        // the cells actually laid out in, for the export's provenance.
        .background(GeometryReader { geo in
            Color.clear.onAppear { gridPaneSize = geo.size }
                .onChange(of: geo.size) { _, size in gridPaneSize = size }
        })
    }

    // MARK: Results

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Button("Copy Text") { copy(textReport()) }
                Button("Copy JSON") { copy(jsonReport()) }
                Button("Clear") { results.removeAll() }
            }
            .disabled(results.isEmpty)

            if results.isEmpty {
                Text("No runs yet. Pick a mode and press Run.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // SwiftUI's `Table` caps at 10 columns, so the on-screen view is
                // the decision-relevant subset (037 §4/§5); mean, p50 and the
                // absolute 60Hz counts are all still in the text/JSON export.
                Table(results) {
                    TableColumn("Mode") { Text($0.mode.title) }
                    TableColumn("Config") {
                        Text("\($0.wrappers.title) · \($0.runIndex == 1 ? "cold" : "warm")")
                    }
                    TableColumn("Verdict") { Text($0.stats.verdict).bold() }
                    TableColumn("Frames") { Text("\($0.stats.frameCount)") }
                    TableColumn("Mean") { Text(ms($0.stats.meanMs)) }
                    TableColumn("p95") { Text(ms($0.stats.p95Ms)) }
                    TableColumn("p99") { Text(ms($0.stats.p99Ms)) }
                    TableColumn(">P") { Text("\($0.stats.hitchesOverPeriodCount)") }
                    TableColumn(">2P") { Text("\($0.stats.hitchesOverDoublePeriodCount)") }
                    TableColumn("Worst") { Text(ms($0.stats.longestFrameMs)) }
                }
                .frame(height: 180)
            }
        }
        .padding(12)
    }

    // MARK: Run

    private func run() async {
        guard let target = scrollTarget else { return }
        isRunning = true
        status = "Running \(mode.title)…"
        // One runloop turn so the "Running…" state paints before the scripted
        // scroll saturates the main thread.
        await Task.yield()

        let viewportHeight = target.viewportHeight
        let stats = await driver.run(
            target: target, recorder: recorder, duration: duration)

        // Run 1 of a given mode+config is cold, 2+ are warm (037 §3.2).
        let priorRuns = results.count { $0.mode == mode && $0.wrappers == wrappers }
        results.append(GridBakeoffResult(
            mode: mode, wrappers: wrappers, runIndex: priorRuns + 1,
            itemCount: model.items.count, durationSeconds: duration,
            viewportHeight: viewportHeight, stats: stats))
        rawIntervals.append(recorder.rawIntervalsMs)
        isRunning = false
        status = stats.frameCount == 0
            ? "Run produced no frames — is the collection taller than the viewport?"
            : "\(mode.title) · \(wrappers.title): \(stats.verdict) "
                + "(p99 \(ms(stats.p99Ms)), \(stats.hitchesOverDoublePeriodCount) over 2P)"
    }

    // MARK: Automated run (037)

    /// Run one configuration `repeats` times, write the JSON envelope, exit.
    ///
    /// Terminates the process in every path, including the failure ones: a
    /// driving script must never be left waiting on a file that will not appear,
    /// and an app left running would violate §3.5 (an orphaned instance was
    /// found running for 23h during the merge) for whatever runs next.
    private func runAutomated(_ config: BakeoffAutorunConfig) async {
        // The display is a controlled variable (037 §3.6) — the refresh period IS
        // the threshold — so log every candidate and which one the window took,
        // rather than only the one it happened to land on.
        for (index, screen) in NSScreen.screens.enumerated() {
            trace("screen[\(index)] \(screen.localizedName) "
                + "\(screen.maximumFramesPerSecond)Hz "
                + "\(Int(screen.frame.width))x\(Int(screen.frame.height)) "
                + "@\(screen.backingScaleFactor)x")
        }
        trace("window on: \(hostWindow?.screen?.localizedName ?? "unknown") "
            + "\(hostWindow?.screen?.maximumFramesPerSecond ?? 0)Hz")
        trace("collection loaded — \(model.items.count) items")
        if model.items.isEmpty {
            finish(.noCollection, message: "no items — \(status)")
        }

        // Close the app's own main window before measuring. It is a second
        // SwiftUI grid over the same library, and leaving it rendering behind
        // the bake-off would put an uncontrolled load on the machine (§3.5).
        for window in NSApp.windows where window.title != "Grid Bake-off" {
            window.close()
        }

        // Ask the system not to nap or throttle timers mid-matrix. Applied
        // identically to every mode, so it cannot favour one.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "grid bake-off measurement")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        guard await waitForScrollTarget() else {
            finish(.noScrollTarget, message: "\(mode.title) registered no scroll target")
        }

        trace("scroll target ready — starting \(config.repeats) ramp(s)")
        for index in 1 ... config.repeats {
            await run()
            trace("ramp \(index): \(status)")
        }

        // Let the grid go quiet before exiting. Purely diagnostic and strictly
        // AFTER every measured frame: the AppKit mode reports its scroll-tick
        // and cell-restock counters from a 2Hz idle poll, and exiting the
        // instant the last ramp ends kills the process before that fires —
        // leaving no evidence in the log that the scripted scroll actually moved
        // the collection view, which is the one thing that would invalidate a
        // suspiciously perfect number.
        try? await Task.sleep(for: .milliseconds(1500))

        if results.allSatisfy({ $0.stats.frameCount == 0 }) {
            finish(.noFrames, message: "every ramp sampled zero frames")
        }
        writeExport(config)
        finish(.success, message: "RESULTS=\(exportedPath) runs=\(results.count)")
    }

    /// Poll until the selected mode publishes its scroll target and the grid has
    /// real travel, or give up.
    ///
    /// Polling rather than a callback because the three modes register from
    /// different places (`.onChange` of geometry for the SwiftUI grids, a
    /// runloop hop after `makeNSView` for AppKit) and the harness must not care
    /// which. The travel check matters as much as the target: a grid that has
    /// laid out but not yet sized its content would ramp over nothing and post a
    /// flattering all-idle number.
    private func waitForScrollTarget(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        var reported = false
        while Date.now < deadline {
            if let target = scrollTarget {
                if !reported {
                    reported = true
                    trace("target registered — content \(target.contentHeight) "
                        + "viewport \(target.viewportHeight)")
                }
            }
            if let target = scrollTarget,
               target.contentHeight - target.viewportHeight > 0 {
                // A short settle so the first ramp measures a laid-out grid
                // rather than its initial layout pass. Identical for every mode.
                try? await Task.sleep(for: .milliseconds(500))
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Write the self-describing results envelope (037 §3).
    private func writeExport(_ config: BakeoffAutorunConfig) {
        let screen = hostWindow?.screen ?? BakeoffEnvironment.screen(at: config.screenIndex)
        let hz = Double(screen?.maximumFramesPerSecond ?? 60)
        let export = BakeoffAutorunExport(
            mode: mode, wrappers: wrappers,
            libraryRoot: BakeoffEnvironment.libraryRootDescription,
            collectionName: Self.collectionName,
            itemCount: model.items.count,
            durationSeconds: duration,
            repeats: config.repeats,
            windowWidth: Double(hostWindow?.frame.width ?? 0),
            windowHeight: Double(hostWindow?.frame.height ?? 0),
            viewportWidth: Double(gridPaneSize.width),
            viewportHeight: results.first?.viewportHeight ?? Double(gridPaneSize.height),
            screenName: screen?.localizedName ?? "unknown",
            screenRefreshHz: hz,
            // Taken from the recorder, not recomputed, so the period the export
            // reports is provably the one the verdicts were scored against.
            refreshPeriodMs: results.first?.stats.refreshPeriodMs ?? recorder.refreshPeriodMs,
            screenBackingScaleFactor: Double(screen?.backingScaleFactor ?? 1),
            screenWidth: Double(screen?.frame.width ?? 0),
            screenHeight: Double(screen?.frame.height ?? 0),
            machine: BakeoffEnvironment.machine,
            osVersion: BakeoffEnvironment.osVersion,
            startedAt: results.first?.timestamp ?? .now,
            runs: results.enumerated().map { index, result in
                BakeoffAutorunExport.Run(
                    runIndex: result.runIndex,
                    cacheState: result.runIndex == 1 ? "cold" : "warm",
                    verdict: result.stats.verdict,
                    stats: result.stats,
                    finishedAt: result.timestamp,
                    intervalsMs: index < rawIntervals.count ? rawIntervals[index] : [])
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(export)
        } catch {
            finish(.writeFailed, message: "could not encode results: \(error)")
        }

        let requested = URL(fileURLWithPath: (config.outPath as NSString).expandingTildeInPath)
        if write(data, to: requested) {
            exportedPath = requested.path
            return
        }
        // The app is SANDBOXED (`com.apple.security.app-sandbox`, only
        // `files.user-selected.read-only`), so an arbitrary absolute path is not
        // writable from inside the container and the requested write fails with
        // EPERM. Falling back to the container's own tmp keeps the numbers —
        // losing a completed matrix cell to a path permission would be absurd —
        // and the real path is printed so the driving script can collect it.
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent(requested.lastPathComponent)
        guard write(data, to: fallback) else {
            finish(.writeFailed, message: "could not write \(requested.path) or \(fallback.path)")
        }
        exportedPath = fallback.path
    }

    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The window hosting this view — for the recorded window frame and screen.
    private var hostWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Grid Bake-off" }
    }

    /// Progress on stderr. An automated run is otherwise silent for its whole
    /// duration, and "still working" is indistinguishable from "wedged" — which
    /// cost a diagnosis once already.
    private func trace(_ message: String) {
        FileHandle.standardError.write(Data(
            "grid-bakeoff: \(message)\n".utf8))
    }

    /// Report on stdout/stderr and terminate with `code`.
    private func finish(_ code: BakeoffExitCode, message: String) -> Never {
        let line = "grid-bakeoff[\(mode.rawValue)/\(wrappers.rawValue)]: \(message)\n"
        let handle = code == .success ? FileHandle.standardOutput : FileHandle.standardError
        handle.write(Data(line.utf8))
        exit(code.rawValue)
    }

    // MARK: Loading

    /// Find the collection named "Bakeoff" and load it. Reports plainly when it
    /// is missing rather than silently measuring an empty grid.
    private func loadBakeoffCollection() async {
        // The model bootstraps asynchronously; wait for it rather than racing it.
        //
        // Polled rather than awaited on `$isReady.values`: an `AsyncPublisher`
        // that has ALREADY passed the value you are waiting for never delivers
        // it again, so the await parks forever. That is a silent hang in the
        // interactive path and a script that never returns in the automated one
        // — observed, then fixed here. Polling cannot miss an edge because it
        // reads the state, not the transition.
        trace("waiting for library bootstrap…")
        guard await poll({ model.isReady }) else {
            status = "Library never became ready."
            return
        }
        await model.refreshFolders()
        guard let folder = model.folders.first(where: {
            $0.name.caseInsensitiveCompare(Self.collectionName) == .orderedSame
        }) else {
            status = "No collection named \"\(Self.collectionName)\" — create one "
                + "and fill it with ~2000 items."
            return
        }
        // Re-issued until it sticks, not fired once. `bootstrap()` loads Unsorted
        // on its own schedule, and `loadContents` cancels any load older than the
        // newest one — so a Bakeoff load requested just before the bootstrap load
        // is silently discarded and the wait never completes. Retrying converges
        // regardless of which order the two land in.
        trace("loading collection \(folder.id)…")
        var attempts = 0
        while model.loadedCollectionID != folder.id, attempts < 12 {
            attempts += 1
            model.loadContents(of: folder.id)
            _ = await poll(timeout: 5) { model.loadedCollectionID == folder.id }
        }
        guard model.loadedCollectionID == folder.id else {
            status = "Collection never finished loading."
            return
        }
        status = "\(model.items.count) items loaded."
    }

    /// Poll `condition` on the main actor until it holds, or the deadline passes.
    private func poll(
        timeout: TimeInterval = 60, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: Export

    private func textReport() -> String {
        // The header carries the controlled variables (037 §3) — a table of
        // numbers without the build configuration and refresh rate cannot be
        // checked against the decision rule, and a Debug run pasted into a
        // discussion would silently damn SwiftUI.
        let period = results.first?.stats.refreshPeriodMs ?? recorder.refreshPeriodMs
        var lines = [
            "Grid bake-off — \(Date.now.formatted())",
            "build: \(BuildConfiguration.current)",
            String(format: "display: %.2fms period (%.0fHz)", period, 1000 / period),
            "verdicts per 037 §4: Smooth = p99 <= P and 0 frames > 2P;"
                + " Acceptable = p95 <= P and < 5 frames > 2P",
            "",
            "mode\twrap\trun\tverdict\titems\tviewport\tsecs\tframes"
                + "\tmean\tp50\tp95\tp99\t>P\t>2P\t>16.7\t>33.4\tworst",
        ]
        for r in results {
            lines.append([
                r.mode.rawValue, r.wrappers.rawValue,
                r.runIndex == 1 ? "cold" : "warm\(r.runIndex)",
                r.stats.verdict, "\(r.itemCount)",
                String(format: "%.0f", r.viewportHeight),
                String(format: "%.0f", r.durationSeconds), "\(r.stats.frameCount)",
                ms(r.stats.meanMs), ms(r.stats.p50Ms), ms(r.stats.p95Ms), ms(r.stats.p99Ms),
                "\(r.stats.hitchesOverPeriodCount)", "\(r.stats.hitchesOverDoublePeriodCount)",
                "\(r.stats.hitches16Count)", "\(r.stats.hitches33Count)",
                ms(r.stats.longestFrameMs),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private func jsonReport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(results),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        status = "Copied \(results.count) run(s) to the clipboard."
    }

    private func ms(_ value: Double) -> String { String(format: "%.2f", value) }
}
