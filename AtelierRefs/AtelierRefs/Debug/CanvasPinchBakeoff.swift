//
//  CanvasPinchBakeoff.swift
//  AtelierRefs
//
//  018 · C7 / 086 — the pinch harness, and the gate it answers.
//
//  018's own sequencing advice for its last unshipped phase is to run the harness
//  FIRST, because it is the instrument that says whether the smoothing is needed at
//  all. This is that instrument for the real, on-screen path: a scripted pinch over a
//  synthetic board, sampled by `FrameTimeRecorder` at the display's actual refresh.
//
//  It reuses 037's measurement stack wholesale rather than porting Easel's
//  `EaselPerf` (018 §E3): `FrameTimeRecorder` + the pure `frameTimeStatistics` already
//  report percentiles, hitch counts against the REAL refresh period, and the longest
//  frame — the tail, which is where a pinch complaint actually lives. A mean would
//  rate this fine while every tenth frame stuttered; 037 §4 chose that pairing after
//  exactly that failure.
//
//  The board is SYNTHETIC (`CanvasRenderer`'s own spike generator), not the user's
//  library. A measurement that depends on which assets someone happens to have is not
//  a measurement, and the numbers from two machines have to be comparable.
//
//      -canvas-pinch-bakeoff arm=both,tiles=500,duration=3,zoom=8,out=/tmp/pinch.json
//
//  `arm=direct` is the pre-086 path (one `zoom()` per event, no gesture); `gesture`
//  is the bracketed one (coalesced to vsync, LOD frozen, one notification at settle).
//  `both` runs them back to back in one launch so the pair is measured on the same
//  window, the same screen and the same thermal state — the only way the difference
//  between them means anything.
//
//
//  099 · 8A — the whole bake-off harness is DEBUG-only.
//
//  It is 2,765 lines across seven files, and until this guard it compiled into
//  every Release build the user ever ran: a grid harness, a pinch harness, a
//  frame-time recorder and a scroll driver, none of them reachable without a
//  launch argument, all of them shipped. `#if DEBUG` is the whole fix — the
//  folder still deletes in one move, and the app the user installs no longer
//  carries it.
//

#if DEBUG

import AppKit
import CanvasRenderer
import Foundation

// MARK: - Configuration

/// One scripted pinch configuration, parsed from the launch arguments.
struct CanvasPinchBakeoffConfig {
    static let launchArgument = "-canvas-pinch-bakeoff"

    enum Arm: String, CaseIterable {
        /// The pre-086 path: `zoom()` per event, sync + notify each time.
        case direct
        /// The 086 path: events accumulate, a display link commits, LOD frozen.
        case gesture
        /// Both, in one launch.
        case both
        /// The CONTROL: a pan of the same board at a fixed zoom. Not a pinch at all,
        /// and that is the point — "is the pinch expensive?" has no meaning except
        /// against what the same board costs when the camera moves without zooming.
        case pan

        var measured: [Arm] { self == .both ? [.direct, .gesture] : [self] }
    }

    var arm: Arm
    /// Tiles on the board. The pre-registered rule (086 · D8) is written against
    /// ~500 — a busy board, not a stress board.
    var tileCount: Int
    /// Seconds per sweep.
    var duration: TimeInterval
    /// Total magnification at the top of the sweep. The sweep zooms in to this and
    /// back out, so an 8 crosses two LOD boundaries in each direction.
    var zoomSpan: CGFloat
    var repeats: Int
    /// Zoom events delivered per VSYNC — the trackpad's report rate expressed
    /// relative to the display's.
    ///
    /// It matters because the coalescing only pays when events outpace the display: a
    /// driver that emits exactly one event per frame gives the gesture arm nothing to
    /// coalesce, and would score the two arms identically no matter how good the
    /// bracket is. A real trackpad reports at ~120Hz, so `2` is the honest default on
    /// a 60Hz panel and `1` measures the floor.
    var eventsPerFrame: Int
    var outPath: String?
    var screenIndex: Int

    static func parse(arguments: [String] = CommandLine.arguments) throws -> Self? {
        guard let flagIndex = arguments.firstIndex(of: launchArgument) else { return nil }
        var fields: [String: String] = [:]
        let payloadIndex = arguments.index(after: flagIndex)
        // The payload is optional here (unlike the grid's): every field has a
        // defensible default, and a bare flag running the standard configuration is
        // what makes this easy to re-run months later without reading the source.
        if payloadIndex < arguments.endIndex, !arguments[payloadIndex].hasPrefix("-") {
            for pair in arguments[payloadIndex].split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    throw AutorunError("malformed field '\(pair)' — expected key=value")
                }
                fields[String(parts[0])] = String(parts[1])
            }
        }

        let armRaw = fields["arm"] ?? Arm.both.rawValue
        guard let arm = Arm(rawValue: armRaw) else {
            throw AutorunError("unknown arm '\(armRaw)' — expected one of "
                + Arm.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let tiles = fields["tiles"].flatMap(Int.init) ?? 500
        guard tiles > 0 else { throw AutorunError("tiles must be > 0") }
        let duration = fields["duration"].flatMap(Double.init) ?? 3
        guard duration > 0 else { throw AutorunError("duration must be > 0") }
        let zoomSpan = fields["zoom"].flatMap(Double.init).map { CGFloat($0) } ?? 8
        guard zoomSpan > 1 else { throw AutorunError("zoom must be > 1") }
        let repeats = fields["repeats"].flatMap(Int.init) ?? 1
        guard repeats > 0 else { throw AutorunError("repeats must be > 0") }
        let screenIndex = fields["screen"].flatMap(Int.init) ?? 0
        guard screenIndex >= 0 else { throw AutorunError("screen must be >= 0") }
        let eventsPerFrame = fields["events"].flatMap(Int.init) ?? 2
        guard eventsPerFrame > 0 else { throw AutorunError("events must be > 0") }

        return Self(arm: arm, tileCount: tiles, duration: duration, zoomSpan: zoomSpan,
                    repeats: repeats, eventsPerFrame: eventsPerFrame,
                    outPath: fields["out"], screenIndex: screenIndex)
    }
}

// MARK: - The board

/// A mixed board — images and text — because the two stress different halves of the
/// renderer under zoom: an image tile can change LOD tier (a decode), a text tile
/// re-rasterizes its glyphs at the new scale. A board of only one kind would answer
/// only half the question.
///
/// Laid out as a dense grid rather than the spike's clustered scatter: a 8x zoom into
/// a clustered board can land the viewport in the empty space BETWEEN clusters, and a
/// sweep that ends up looking at nothing measures nothing. (Observed, headlessly:
/// 1,887 tiles visible at the start of such a sweep and zero at the top of it.)
struct CanvasPinchBoard: TileProvider {
    let tiles: [Tile]
    private let styles: [Int: TextStyle]

    init(count: Int) {
        let cols = max(1, Int(Double(count).squareRoot().rounded()))
        let pitch = 260.0
        var tiles: [Tile] = []
        var styles: [Int: TextStyle] = [:]
        for i in 0..<count {
            let (row, col) = (i / cols, i % cols)
            tiles.append(Tile(
                id: i, x: Double(col) * pitch, y: Double(row) * pitch, w: 200, h: 200, z: i))
            // Every fourth tile is text. Enough to make the glyph raster path a real
            // part of the frame without turning an image benchmark into a text one.
            if i.isMultiple(of: 4) {
                styles[i] = TextStyle(
                    string: "Note \(i) — the quick brown fox jumps over the lazy dog and "
                        + "keeps running past the edge of the box.",
                    fontSize: 15 + Double(i % 4),
                    color: RGBAColor(red: 0.1, green: 0.1, blue: 0.1))
            }
        }
        self.tiles = tiles
        self.styles = styles
    }

    func content(for tile: Tile) -> TileContent {
        styles[tile.id].map { .text($0) } ?? .image
    }
}

/// Fixture bytes with one image identity PER TILE. The spike's set shares 24 images
/// across the whole board, which lets the thumbnail cache fill after a few frames and
/// hides the decode path completely — the opposite of a real library, where every
/// asset is its own decode.
struct CanvasPinchImages: TileImageSource {
    private let base: FixtureImageSet

    init(seed: UInt64 = 0x9C7) { base = FixtureImageSet(count: 24, seed: seed) }

    func imageKey(for tile: Tile) -> Int { tile.id }
    func imageData(for tile: Tile, tier: LODTier) -> Data? { base.imageData(for: tile, tier: tier) }
}

// MARK: - The driver

/// Runs one scripted pinch while a ``FrameTimeRecorder`` samples it.
///
/// Driver and recorder share ONE display link — the recorder's — exactly as
/// ``BakeoffScrollDriver`` does, so a zoom step can never land between two sampled
/// frames and pair a magnification with the wrong interval.
@MainActor
final class CanvasPinchDriver {
    private(set) var isRunning = false

    /// Sweep `host` from 1x up to `zoomSpan` and back over `duration`, sampled by
    /// `recorder`, and return the run's statistics.
    ///
    /// The magnification is integrated from each frame's REAL duration rather than
    /// counted in ticks: on a 120Hz panel a tick is 8.3ms and on 60Hz it is 16.7ms, so
    /// a fixed per-tick factor would sweep twice as far on ProMotion in the same
    /// wall-clock time and the two machines' runs would not be comparable.
    @discardableResult
    func run(
        host: CanvasHostView,
        arm: CanvasPinchBakeoffConfig.Arm,
        zoomSpan: CGFloat,
        duration: TimeInterval,
        eventsPerFrame: Int = 2,
        recorder: FrameTimeRecorder
    ) async -> FrameTimeStats {
        guard !isRunning, duration > 0, zoomSpan > 1 else { return .empty }
        isRunning = true
        defer { isRunning = false }

        let anchor = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        // Where the sweep should be at a given progress: in for the first half, back
        // out for the second, as a multiple of the starting scale.
        func target(at progress: Double) -> CGFloat {
            let triangle = progress < 0.5 ? progress * 2 : (1 - progress) * 2
            return pow(zoomSpan, CGFloat(triangle))
        }

        let startScale = host.camera.zoom
        if arm == .gesture { host.beginZoomGesture(anchorScreenPoint: anchor) }

        var elapsed: TimeInterval = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didFinish = false
            recorder.onFrame = { [weak host] dt in
                guard !didFinish, let host else { return }
                elapsed += dt
                let progress = min(elapsed / duration, 1)
                // Drive to an ABSOLUTE scale rather than applying a per-frame factor:
                // a dropped frame then costs a bigger step, not a shorter sweep, so
                // every run covers the same zoom range whatever the frame rate did.
                let wanted = startScale * target(at: progress)
                let factor = wanted / max(host.camera.zoom, .leastNonzeroMagnitude)
                if factor.isFinite, factor > 0 {
                    // Split the frame's magnification across `eventsPerFrame` events,
                    // so the camera travels the same distance however many events
                    // carry it there. The direct arm pays a full sync for each; the
                    // gesture arm accumulates them and its link commits once.
                    let step = pow(factor, 1 / CGFloat(eventsPerFrame))
                    for _ in 0..<eventsPerFrame {
                        switch arm {
                        case .direct, .both: host.zoom(by: step, aroundScreenPoint: anchor)
                        case .gesture: host.updateZoomGesture(by: step)
                        case .pan:
                            // Same event count, same board, no zoom: an oscillating
                            // pan that keeps the camera over the content.
                            let dx: CGFloat = (Int(elapsed * 8) % 2 == 0) ? -6 : 6
                            host.pan(byScreenDelta: CGSize(width: dx, height: 3))
                        }
                    }
                }
                if progress >= 1 {
                    didFinish = true
                    continuation.resume()
                }
            }
            recorder.start()
        }

        recorder.onFrame = nil
        if arm == .gesture { host.endZoomGesture() }
        return recorder.stop()
    }
}

// MARK: - The export envelope

/// A complete pinch session: the controlled variables plus every sweep.
struct CanvasPinchExport: Codable {
    var schema = "canvas-pinch-bakeoff/1"
    var buildConfiguration: String = BuildConfiguration.current
    var isRelease: Bool = BuildConfiguration.isRelease

    var tileCount: Int
    var durationSeconds: Double
    var zoomSpan: Double
    var eventsPerFrame: Int
    var viewportWidth: Double
    var viewportHeight: Double

    var screenName: String
    var screenRefreshHz: Double
    var refreshPeriodMs: Double

    var machine: String
    var osVersion: String
    var startedAt: Date
    var runs: [Run]

    struct Run: Codable {
        var arm: String
        var runIndex: Int
        /// `cold` on the first sweep of a fresh process (empty thumbnail cache),
        /// `warm` after. A pinch's decode churn only exists while the cache is cold,
        /// so the split is load-bearing here rather than incidental.
        var cacheState: String
        /// The 086 · D8 verdict, computed from `stats` at export time.
        var verdict: String
        var stats: FrameTimeStats
        var intervalsMs: [Double]
    }
}

/// The pre-registered rule (086 · D8), applied to one sweep.
///
/// Written down before the first run and evaluated in code so it cannot be
/// rationalised afterwards: smoothing is justified if the tail is fat (p99 past two
/// frame budgets) OR hitching is sustained (>2% of frames over the refresh period).
enum CanvasPinchVerdict {
    static let hitchFraction = 0.02

    static func verdict(for stats: FrameTimeStats) -> String {
        guard stats.frameCount > 0 else { return "no frames" }
        let fatTail = stats.p99Ms > 2 * stats.refreshPeriodMs
        let hitchRate = Double(stats.hitchesOverPeriodCount) / Double(stats.frameCount)
        let sustained = hitchRate > hitchFraction
        guard fatTail || sustained else { return "within budget — smoothing not justified" }
        return "over budget — "
            + [fatTail ? "fat tail (p99 \(rounded(stats.p99Ms))ms > "
                + "\(rounded(2 * stats.refreshPeriodMs))ms)" : nil,
               sustained ? "sustained hitching (\(rounded(hitchRate * 100))% of frames)" : nil]
                .compactMap { $0 }.joined(separator: ", ")
    }

    private static func rounded(_ value: Double) -> String { String(format: "%.1f", value) }
}

// MARK: - Launch

/// Opens the pinch harness under `-canvas-pinch-bakeoff`, runs the configured arms,
/// writes the export, and terminates. Absent the flag, nothing here runs.
///
/// A plain object rather than a second `NSApplicationDelegate`: an app has exactly
/// one delegate, and 037's already holds the seat. ``GridBakeoffAppDelegate`` calls
/// this before its own flag check, so the two harnesses are independent despite
/// sharing the hook.
@MainActor
final class CanvasPinchBakeoffLauncher {
    /// Fixed, and not resizable in an automated run: the viewport sets how many tiles
    /// are visible, which is the single biggest input to per-frame cost.
    static let contentSize = NSSize(width: 1_440, height: 900)

    /// Held for the process's lifetime by the caller, so neither the window nor the
    /// running sweep is collected mid-measurement.
    static let shared = CanvasPinchBakeoffLauncher()

    private var window: NSWindow?

    func launchIfRequested() {
        let config: CanvasPinchBakeoffConfig?
        do {
            config = try CanvasPinchBakeoffConfig.parse()
        } catch {
            FileHandle.standardError.write(Data("canvas-pinch-bakeoff: \(error)\n".utf8))
            exit(BakeoffExitCode.badArguments.rawValue)
        }
        guard let config else { return }

        let board = CanvasPinchBoard(count: config.tileCount)
        let host = CanvasHostView(
            provider: board, images: CanvasPinchImages(),
            frame: NSRect(origin: .zero, size: Self.contentSize))
        host.framesContentWhenReady = true

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Canvas Pinch Bake-off"
        window.contentView = host
        place(window, on: BakeoffEnvironment.screen(at: config.screenIndex))
        window.makeKeyAndOrderFront(nil)
        // Frontmost and unoccluded: the window server throttles a background or
        // covered window's display link, which would measure the throttle.
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        Task { @MainActor in await self.runMatrix(config: config, host: host) }
    }

    private func runMatrix(config: CanvasPinchBakeoffConfig, host: CanvasHostView) async {
        let recorder = FrameTimeRecorder()
        recorder.hostView = host
        let driver = CanvasPinchDriver()

        // One frame of settle so the first sweep is not measuring the window's own
        // first paint.
        try? await Task.sleep(for: .milliseconds(500))

        var runs: [CanvasPinchExport.Run] = []
        var sweepIndex = 0
        for arm in config.arm.measured {
            for run in 1...config.repeats {
                let startCamera = host.camera
                // A sweep advances only when the display link fires. If it never does
                // — the window is off-screen, the process has no usable window server
                // connection, the display is asleep — the `await` below would hang
                // forever and a driving script would wait on a file that is never
                // written. Fail loudly instead, with the one diagnosis that matters.
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(config.duration + 10))
                    guard !Task.isCancelled else { return }
                    FileHandle.standardError.write(Data(
                        ("canvas-pinch-bakeoff: no vsync in \(Int(config.duration) + 10)s — "
                         + "the harness window is not being displayed (run it on a live, "
                         + "unlocked session with the window frontmost)\n").utf8))
                    exit(BakeoffExitCode.noFrames.rawValue)
                }
                let stats = await driver.run(
                    host: host, arm: arm, zoomSpan: config.zoomSpan,
                    duration: config.duration, eventsPerFrame: config.eventsPerFrame,
                    recorder: recorder)
                watchdog.cancel()
                sweepIndex += 1
                let verdict = CanvasPinchVerdict.verdict(for: stats)
                runs.append(CanvasPinchExport.Run(
                    arm: arm.rawValue, runIndex: run,
                    cacheState: sweepIndex == 1 ? "cold" : "warm",
                    verdict: verdict, stats: stats, intervalsMs: recorder.rawIntervalsMs))
                print("[canvas-pinch] arm=\(arm.rawValue) run=\(run) "
                    + "tiles=\(config.tileCount) events/frame=\(config.eventsPerFrame) "
                    + "frames=\(stats.frameCount) "
                    + "p50=\(fmt(stats.p50Ms)) p95=\(fmt(stats.p95Ms)) p99=\(fmt(stats.p99Ms)) "
                    + "max=\(fmt(stats.longestFrameMs)) "
                    + "over-refresh=\(stats.hitchesOverPeriodCount)/\(stats.frameCount) "
                    + "P=\(fmt(stats.refreshPeriodMs))ms → \(verdict)")
                // stdout is fully buffered when redirected to a file, and a run that
                // is watched by tailing that file would otherwise show nothing until
                // the process exits.
                fflush(stdout)
                // Return the camera so every sweep starts from the same place.
                host.setCamera(startCamera)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        guard !runs.isEmpty, runs.contains(where: { $0.stats.frameCount > 0 }) else {
            FileHandle.standardError.write(Data("canvas-pinch-bakeoff: no frames sampled\n".utf8))
            exit(BakeoffExitCode.noFrames.rawValue)
        }

        let screen = BakeoffEnvironment.screen(at: config.screenIndex)
        let export = CanvasPinchExport(
            tileCount: config.tileCount, durationSeconds: config.duration,
            zoomSpan: Double(config.zoomSpan), eventsPerFrame: config.eventsPerFrame,
            viewportWidth: Double(host.bounds.width), viewportHeight: Double(host.bounds.height),
            screenName: screen?.localizedName ?? "unknown",
            screenRefreshHz: Double(screen?.maximumFramesPerSecond ?? 0),
            refreshPeriodMs: recorder.refreshPeriodMs,
            machine: BakeoffEnvironment.machine, osVersion: BakeoffEnvironment.osVersion,
            startedAt: .now, runs: runs)

        if let path = config.outPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                try encoder.encode(export).write(to: URL(fileURLWithPath: path))
                print("[canvas-pinch] wrote \(path)")
            } catch {
                FileHandle.standardError.write(Data("canvas-pinch-bakeoff: \(error)\n".utf8))
                exit(BakeoffExitCode.writeFailed.rawValue)
            }
        }
        exit(BakeoffExitCode.success.rawValue)
    }

    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Pin the window to a KNOWN screen: this machine has a ProMotion panel and a
    /// 60Hz one, and the refresh period IS the threshold.
    private func place(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { window.center(); return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}

#endif  // DEBUG
