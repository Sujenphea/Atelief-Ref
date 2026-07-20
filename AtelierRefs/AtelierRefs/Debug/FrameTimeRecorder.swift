//
//  FrameTimeRecorder.swift
//  AtelierRefs
//
//  037 — frame-time measurement for the three-way grid bake-off (035 §5 asks
//  whether the AppKit rewrite is worth 1–2 weeks; that question is only
//  answerable with NUMBERS, from all three grids, under an IDENTICAL scroll).
//
//  Why a display link and not wall-clock sampling: the thing users feel is not
//  mean frame time, it is the LONG TAIL — the band-boundary re-materialization
//  (035 §4) shows up as a periodic ~40–80ms frame while the mean stays near
//  8ms. A mean-only metric would rate the current grid "fine" and hide exactly
//  the defect the rewrite is meant to fix. So the recorder keeps every interval
//  and reports percentiles + hitch COUNTS, where the regression actually lives.
//
//  The split mirrors the house pattern (`GridWindowing`, `MarqueeMath`):
//
//   • ``frameTimeStatistics(intervalsMs:)`` — PURE, SwiftUI-free, exhaustively
//     unit-tested (`FrameTimeStatsTests`). All the arithmetic that could be
//     wrong lives here, where it can be checked against hand-computed answers.
//   • ``FrameTimeRecorder`` — the thin, untestable I/O shell: owns a
//     `CADisplayLink` and appends deltas. It contains no statistics logic at
//     all, so "the numbers are wrong" is always a question about the pure
//     function.
//
//  Display-link API note: on macOS a `CADisplayLink` is VENDED BY A VIEW
//  (`NSView.displayLink(target:selector:)`, macOS 14+) — there is no
//  free-standing initializer as on iOS. This mirrors the already-shipping
//  `DisplayLinkPump` in `GridMarquee.swift`, which is the verified-correct call
//  for this toolchain.
//

import AppKit
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Pure statistics

/// The frame-time summary of one bake-off run — the comparable unit across the
/// three grid implementations (037).
///
/// Times are MILLISECONDS (the unit the 16.7 / 33.4ms budgets are stated in, so
/// the numbers read directly against them); `duration` alone is seconds.
/// `Codable` so a bake-off session exports as JSON and runs from different
/// machines or branches can be diffed. Declared here rather than in an extension
/// because Swift only synthesizes the conformance in the declaring file.
struct FrameTimeStats: Equatable, Codable {
    /// How many frame intervals were sampled. Note this is intervals, so a run
    /// that saw N display-link fires yields N−1 frames.
    var frameCount: Int
    /// Wall-clock span of the run in SECONDS — the sum of every interval.
    var duration: Double

    var meanMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var p99Ms: Double

    /// Frames that missed a 60Hz budget (> 16.7ms) — a dropped frame on a
    /// standard display.
    var hitches16Count: Int
    /// Frames that took longer than TWO 60Hz budgets (> 33.4ms) — a visible
    /// stutter, not a subtle one. This is the count that should collapse if the
    /// AppKit rewrite is worth doing.
    var hitches33Count: Int
    /// The single worst frame in the run, in ms — the worst-case jank.
    var longestFrameMs: Double

    /// The display's refresh period `P` in ms that the two counts below are
    /// measured against (8.33 at 120Hz, 16.7 at 60Hz).
    var refreshPeriodMs: Double
    /// Frames over `P` — the `> P` count the 037 decision rule reads.
    ///
    /// Expressed relative to the real refresh period rather than a fixed 16.7ms
    /// because the verdict thresholds must not move with the test machine: on a
    /// ProMotion display a 12ms frame IS a dropped frame, but the absolute
    /// 60Hz counts above would score it perfect. Both are reported so a run is
    /// comparable against the pre-registered rule AND against a plain 60Hz
    /// budget.
    var hitchesOverPeriodCount: Int
    /// Frames over `2P` — the `> 2P` count the 037 decision rule reads.
    var hitchesOverDoublePeriodCount: Int

    /// An all-zero summary — the honest answer for a run that sampled nothing,
    /// rather than a crash or a NaN that would poison a comparison table.
    static let empty = FrameTimeStats(
        frameCount: 0, duration: 0, meanMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0,
        hitches16Count: 0, hitches33Count: 0, longestFrameMs: 0,
        refreshPeriodMs: frameBudget60Ms,
        hitchesOverPeriodCount: 0, hitchesOverDoublePeriodCount: 0)

    /// The 037 §4 verdict for this run, applied mechanically to the `> P` and
    /// `> 2P` counts so the outcome cannot be rationalised after the fact.
    var verdict: String {
        if frameCount == 0 { return "no data" }
        if p99Ms <= refreshPeriodMs, hitchesOverDoublePeriodCount == 0 { return "Smooth" }
        if p95Ms <= refreshPeriodMs, hitchesOverDoublePeriodCount < 5 { return "Acceptable" }
        return "Not smooth"
    }
}

/// The 60Hz frame budget in ms — one frame at 60Hz is 16.67ms.
let frameBudget60Ms: Double = 16.7
/// Two 60Hz budgets. A frame past this dropped at least two frames and reads as
/// a visible stutter rather than a soft one.
let frameBudget30Ms: Double = 33.4

/// Summarize a run's frame intervals (037) — PURE, so every number below is
/// checkable against a hand-computed answer in `FrameTimeStatsTests`.
///
/// Input is one entry per FRAME INTERVAL, in milliseconds. Non-finite and
/// non-positive samples are DROPPED rather than propagated: a display link
/// reports a garbage delta on its first fire (there is no previous timestamp to
/// difference against) and can report a zero delta if two callbacks coalesce
/// into one vsync — either would otherwise drag the mean down and understate
/// the jank, which is the one direction this measurement must never fail in.
///
/// Percentiles use the NEAREST-RANK method on the ascending sorted samples:
/// `p(q)` is the element at index `ceil(q · n) − 1`, clamped into range. Chosen
/// over interpolation because the answer is always an ACTUAL OBSERVED FRAME —
/// "p99 = 41.2ms" names a frame that really happened, so it can be found in a
/// trace. Interpolation would invent values between real frames.
///
/// Hitches count strictly-greater-than, so a frame landing exactly on budget is
/// not a hitch.
///
/// `refreshPeriodMs` is the display's real period `P`, used for the `> P` /
/// `> 2P` counts the 037 decision rule reads. It defaults to the 60Hz budget so
/// a caller that doesn't know the display still gets sane numbers; a
/// non-positive value falls back to that default rather than dividing the
/// verdict by zero.
func frameTimeStatistics(
    intervalsMs: [Double], refreshPeriodMs: Double = frameBudget60Ms
) -> FrameTimeStats {
    let period = refreshPeriodMs.isFinite && refreshPeriodMs > 0
        ? refreshPeriodMs : frameBudget60Ms
    // Drop the samples that carry no information (see above) BEFORE any
    // arithmetic, so a bogus first delta can't reach the mean or the sort.
    let samples = intervalsMs.filter { $0.isFinite && $0 > 0 }
    guard !samples.isEmpty else {
        var empty = FrameTimeStats.empty
        empty.refreshPeriodMs = period
        return empty
    }

    let sorted = samples.sorted()
    let n = sorted.count
    let total = sorted.reduce(0, +)

    /// Nearest-rank percentile over the already-sorted samples.
    func percentile(_ q: Double) -> Double {
        let rank = Int((q * Double(n)).rounded(.up))
        // Clamp both ends: q = 0 would rank 0, and floating-point drift on
        // q · n could rank n + 1. Both must stay a valid index.
        return sorted[min(max(rank - 1, 0), n - 1)]
    }

    return FrameTimeStats(
        frameCount: n,
        // Seconds — the samples are ms.
        duration: total / 1000,
        meanMs: total / Double(n),
        p50Ms: percentile(0.50),
        p95Ms: percentile(0.95),
        p99Ms: percentile(0.99),
        hitches16Count: sorted.count { $0 > frameBudget60Ms },
        hitches33Count: sorted.count { $0 > frameBudget30Ms },
        // The sort is ascending, so the worst frame is the last element.
        longestFrameMs: sorted[n - 1],
        refreshPeriodMs: period,
        hitchesOverPeriodCount: sorted.count { $0 > period },
        hitchesOverDoublePeriodCount: sorted.count { $0 > 2 * period })
}

// MARK: - Recording shell

/// Samples frame intervals off a `CADisplayLink` for the duration of one
/// bake-off run (037). Deliberately logic-free: it collects deltas and hands
/// them to ``frameTimeStatistics(intervalsMs:)``, so there is nothing here that
/// can compute a wrong number.
///
/// The link must be vended by a live `NSView` (see the file header), supplied by
/// ``BakeoffDisplayLinkHost``.
@MainActor
final class FrameTimeRecorder {
    /// The view whose display the link syncs to — installed by
    /// ``BakeoffDisplayLinkHost``. Weak: the host view outlives nothing here.
    weak var hostView: NSView?

    /// Called on every vsync while recording, with that frame's real interval in
    /// SECONDS. The scroll driver hangs its offset step off this so the scroll
    /// and the measurement ride the SAME link — one clock, so a step can never
    /// land between two sampled frames and skew the pairing.
    var onFrame: (@MainActor (CFTimeInterval) -> Void)?

    private(set) var isRecording = false

    private var link: CADisplayLink?
    private var intervalsMs: [Double] = []
    /// The previous fire's timestamp. `nil` on the first fire — which is exactly
    /// why the first fire contributes NO sample (there is nothing to difference
    /// against), rather than a fabricated one.
    private var lastTimestamp: CFTimeInterval?

    /// Begin a run. Clears any previous samples so runs never bleed together.
    /// No-op without a host view (nothing to vend the link) or if already
    /// recording.
    func start() {
        guard !isRecording, let hostView else { return }
        intervalsMs.removeAll(keepingCapacity: true)
        lastTimestamp = nil
        // `.common` mode so the link is not starved while the run drives scroll
        // updates through the main runloop — the same reason `DisplayLinkPump`
        // uses it during a marquee drag.
        let link = hostView.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        isRecording = true
    }

    /// End the run and summarize it. Idempotent — stopping a stopped recorder
    /// returns the last run's statistics rather than clearing them, so the UI can
    /// re-read the result.
    @discardableResult
    func stop() -> FrameTimeStats {
        link?.invalidate()
        link = nil
        isRecording = false
        return statistics
    }

    /// The current statistics — readable mid-run (a live readout) or after
    /// ``stop()``.
    var statistics: FrameTimeStats {
        frameTimeStatistics(intervalsMs: intervalsMs, refreshPeriodMs: refreshPeriodMs)
    }

    /// The host display's refresh period in ms — 8.33 on a 120Hz panel, 16.7 on
    /// 60Hz. Read from the screen the host view is actually on (a laptop with an
    /// external monitor has two different answers, and the one that matters is
    /// wherever the window sits). Falls back to 60Hz when there is no screen yet.
    ///
    /// 037 §3.6 requires the display's refresh be recorded with every run,
    /// because an adaptive-refresh panel changes the frame budget and therefore
    /// the verdict.
    var refreshPeriodMs: Double {
        let fps = hostView?.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        guard fps > 0 else { return frameBudget60Ms }
        return 1000 / Double(fps)
    }

    /// The raw intervals in ms, for a per-frame CSV export.
    var rawIntervalsMs: [Double] { intervalsMs }

    @objc nonisolated private func step(_ link: CADisplayLink) {
        // The link fires on the main runloop, so isolation is satisfied in fact;
        // assume it to call back into `@MainActor` state without a hop that would
        // itself add latency to the thing being measured.
        MainActor.assumeIsolated {
            let now = link.timestamp
            if let last = lastTimestamp {
                // The ACTUAL elapsed time between vsyncs — NOT
                // `targetTimestamp − timestamp`, which is the display's NOMINAL
                // frame duration and stays a flat 8.3ms even while frames are
                // being missed. Differencing consecutive timestamps is what makes
                // a dropped frame visible as a long interval.
                intervalsMs.append((now - last) * 1000)
            }
            lastTimestamp = now
            let dt = link.targetTimestamp - link.timestamp
            onFrame?(dt)
        }
    }
}

/// Installs a hit-transparent `NSView` purely so ``FrameTimeRecorder`` has a view
/// to vend its `CADisplayLink` from (037) — the same trick `DisplayLinkHost`
/// plays for the marquee pump, kept separate so this spike stays deletable
/// without touching shipping code.
struct BakeoffDisplayLinkHost: NSViewRepresentable {
    let recorder: FrameTimeRecorder

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        recorder.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        recorder.hostView = nsView
    }

    /// Never claims a hit, so the grid under measurement keeps every event it
    /// would have received unmeasured — the harness must not change what it
    /// measures.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
