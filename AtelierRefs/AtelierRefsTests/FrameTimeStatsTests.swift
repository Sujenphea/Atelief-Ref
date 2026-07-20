//
//  FrameTimeStatsTests.swift
//  AtelierRefsTests
//
//  037 — the bake-off's statistics, exhaustively. This function decides whether
//  a 1–2 week AppKit rewrite happens (035 §5), so a quiet arithmetic error here
//  would mis-spend a fortnight. The recording shell around it is untestable I/O
//  by design; ALL the arithmetic lives here, checked against hand-computed
//  answers.
//
//  What is pinned:
//   • the exact mean / percentile / hitch / max arithmetic on known inputs
//   • the NEAREST-RANK percentile contract — every percentile is an actually
//     observed frame, never an interpolated invention
//   • hitch thresholds are STRICTLY greater-than (on budget is not a hitch)
//   • garbage samples (non-finite, zero, negative) are dropped, never averaged
//     in — the one failure direction that would UNDERSTATE jank and wrongly
//     exonerate a slow grid
//   • the degenerate inputs (empty, single, all-identical) stay finite
//   • the properties that must hold for ANY input: ordering of percentiles,
//     hitch-count nesting, and order-independence
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("frameTimeStatistics: arithmetic on known input")
struct FrameTimeStatsArithmeticTests {

    @Test("mean, max and duration on a hand-computed sample")
    func meanMaxDuration() {
        // Sum = 10 + 20 + 30 + 40 = 100ms over 4 frames → mean 25ms, 0.1s total.
        let stats = frameTimeStatistics(intervalsMs: [10, 20, 30, 40])
        #expect(stats.frameCount == 4)
        #expect(stats.meanMs == 25)
        #expect(stats.longestFrameMs == 40)
        // ms → seconds.
        #expect(abs(stats.duration - 0.1) < 1e-12)
    }

    @Test("percentiles use nearest rank: index ceil(q·n) − 1 on the sorted samples")
    func nearestRankPercentiles() {
        // n = 100, samples 1...100 shuffled. Nearest rank:
        //   p50 → ceil(0.50·100) − 1 = index 49 → 50
        //   p95 → ceil(0.95·100) − 1 = index 94 → 95
        //   p99 → ceil(0.99·100) − 1 = index 98 → 99
        let samples = (1...100).map(Double.init).shuffled()
        let stats = frameTimeStatistics(intervalsMs: samples)
        #expect(stats.p50Ms == 50)
        #expect(stats.p95Ms == 95)
        #expect(stats.p99Ms == 99)
    }

    @Test("every percentile is a REAL observed frame, never an interpolated value")
    func percentilesAreObservedValues() {
        // Deliberately gappy: an interpolating method would return values in the
        // gaps (e.g. 12.5), which could not be found in a trace.
        let samples: [Double] = [8, 8, 8, 9, 100]
        let observed = Set(samples)
        let stats = frameTimeStatistics(intervalsMs: samples)
        #expect(observed.contains(stats.p50Ms))
        #expect(observed.contains(stats.p95Ms))
        #expect(observed.contains(stats.p99Ms))
        #expect(observed.contains(stats.longestFrameMs))
    }

    @Test("the long tail survives a fast mean — the whole reason percentiles exist")
    func tailNotHiddenByMean() {
        // 035 §4's actual shape: a fast grid with a periodic band-crossing hitch.
        // 98 frames at 8ms plus two 80ms stalls → the mean stays a healthy
        // ~9.4ms, but p99 and the hitch counts must expose the stalls.
        var samples = Array(repeating: 8.0, count: 98)
        samples.append(contentsOf: [80, 80])
        let stats = frameTimeStatistics(intervalsMs: samples)
        #expect(stats.meanMs < 10)         // mean says "fine"
        #expect(stats.p99Ms == 80)         // p99 says otherwise
        #expect(stats.hitches33Count == 2)
        #expect(stats.longestFrameMs == 80)
    }

    @Test("p99 needs ≥2 outliers in 100 samples — nearest rank, documented not accidental")
    func p99RankBoundary() {
        // Pins the exact nearest-rank boundary so nobody 'fixes' it into
        // interpolation later: p99 of n=100 is index ceil(0.99·100) − 1 = 98,
        // i.e. the 99th smallest. With a SINGLE outlier the 99th smallest is
        // still a fast frame, so p99 reads 8ms and only `longestFrameMs` and the
        // hitch counts catch it.
        //
        // This is fine at real run sizes (10s × 120Hz ≈ 1200 frames, so p99
        // covers the worst 12), but it is why the harness reports hitch COUNTS
        // and the longest frame alongside percentiles: for a RARE stall those
        // are the sensitive metrics, not p99.
        var one = Array(repeating: 8.0, count: 99)
        one.append(80)
        let stats = frameTimeStatistics(intervalsMs: one)
        #expect(stats.p99Ms == 8)              // the outlier is past p99's rank
        #expect(stats.longestFrameMs == 80)    // but never lost
        #expect(stats.hitches33Count == 1)
    }
}

@Suite("frameTimeStatistics: hitch counting")
struct FrameTimeHitchTests {

    @Test("hitches count strictly greater than budget — a frame ON budget is not a hitch")
    func strictlyGreaterThan() {
        // Exactly on each threshold: neither counts.
        let onBudget = frameTimeStatistics(intervalsMs: [frameBudget60Ms, frameBudget30Ms])
        #expect(onBudget.hitches16Count == 1)   // only the 33.4 sample exceeds 16.7
        #expect(onBudget.hitches33Count == 0)   // 33.4 is ON the 33.4 budget

        let justOver = frameTimeStatistics(intervalsMs: [frameBudget30Ms + 0.001])
        #expect(justOver.hitches33Count == 1)
    }

    @Test("the 33.4ms count is a strict subset of the 16.7ms count")
    func hitchCountsNest() {
        // Any frame over 33.4 is necessarily over 16.7, so the counts must nest
        // for every input — a violation would mean the thresholds got swapped.
        let inputs: [[Double]] = [
            [8, 8, 8],
            [8, 17, 34, 50],
            [16.7, 33.4, 33.5, 100],
            (1...200).map { Double($0) / 3 },
        ]
        for samples in inputs {
            let stats = frameTimeStatistics(intervalsMs: samples)
            #expect(stats.hitches33Count <= stats.hitches16Count)
        }
    }

    @Test("a smooth 120Hz run reports no hitches at all")
    func smoothRunHasNoHitches() {
        let stats = frameTimeStatistics(intervalsMs: Array(repeating: 8.33, count: 500))
        #expect(stats.hitches16Count == 0)
        #expect(stats.hitches33Count == 0)
        #expect(stats.longestFrameMs == 8.33)
    }
}

@Suite("frameTimeStatistics: refresh-relative thresholds and the 037 verdict")
struct FrameTimeVerdictTests {

    /// A 120Hz panel: P = 8.33ms, 2P = 16.67ms.
    private static let promotion = 1000.0 / 120

    @Test("hitch counts follow the REAL refresh period, not a fixed 60Hz budget")
    func countsAreRefreshRelative() {
        // 12ms frames are comfortably inside a 60Hz budget but are DROPPED
        // frames on a 120Hz panel. The absolute counts must say "fine" and the
        // period-relative counts must say "dropped" — that divergence is the
        // whole reason both are reported.
        let stats = frameTimeStatistics(
            intervalsMs: Array(repeating: 12.0, count: 100),
            refreshPeriodMs: Self.promotion)
        #expect(stats.hitches16Count == 0)          // 12 < 16.7
        #expect(stats.hitchesOverPeriodCount == 100) // 12 > 8.33
        #expect(stats.hitchesOverDoublePeriodCount == 0) // 12 < 16.67
    }

    @Test("the >2P count is a subset of the >P count, at any refresh rate")
    func periodCountsNest() {
        for period in [1000.0 / 120, 1000.0 / 60, 1000.0 / 144] {
            for run in [[8.0, 20, 40], (1...200).map { Double($0) / 5 }] {
                let s = frameTimeStatistics(intervalsMs: run, refreshPeriodMs: period)
                #expect(s.hitchesOverDoublePeriodCount <= s.hitchesOverPeriodCount)
            }
        }
    }

    @Test("a non-positive or non-finite refresh period falls back to 60Hz")
    func degeneratePeriodFallsBack() {
        // A window with no screen yet must not divide the verdict by zero.
        let baseline = frameTimeStatistics(intervalsMs: [8, 20, 40])
        for bogus in [0.0, -5, .nan, .infinity] {
            #expect(frameTimeStatistics(intervalsMs: [8, 20, 40], refreshPeriodMs: bogus)
                == baseline)
        }
    }

    @Test("verdict: Smooth requires p99 within P and zero frames over 2P")
    func smoothVerdict() {
        let smooth = frameTimeStatistics(
            intervalsMs: Array(repeating: 8.0, count: 500),
            refreshPeriodMs: Self.promotion)
        #expect(smooth.verdict == "Smooth")

        // One 2P-buster is enough to lose Smooth, however good the rest is —
        // 035 §4's residual is exactly "rare but visible".
        var oneStall = Array(repeating: 8.0, count: 499)
        oneStall.append(50)
        #expect(frameTimeStatistics(intervalsMs: oneStall, refreshPeriodMs: Self.promotion)
            .verdict != "Smooth")
    }

    @Test("verdict: Acceptable tolerates up to four frames over 2P, Not smooth at five")
    func acceptableBoundary() {
        /// 500 frames at 8ms with `stalls` frames replaced by a 50ms stall.
        func run(stalls: Int) -> FrameTimeStats {
            var samples = Array(repeating: 8.0, count: 500 - stalls)
            samples.append(contentsOf: Array(repeating: 50.0, count: stalls))
            return frameTimeStatistics(intervalsMs: samples, refreshPeriodMs: Self.promotion)
        }
        // p95 stays at 8ms until stalls exceed 5% of the run, so the >2P count
        // is what moves the verdict across this boundary.
        #expect(run(stalls: 4).verdict == "Acceptable")
        #expect(run(stalls: 5).verdict == "Not smooth")
    }

    @Test("verdict: an empty run reports no data, never a flattering Smooth")
    func emptyIsNotSmooth() {
        // The dangerous failure: a run that measured nothing must not read as a
        // pass and green-light (or kill) a fortnight of work.
        #expect(FrameTimeStats.empty.verdict == "no data")
        #expect(frameTimeStatistics(intervalsMs: []).verdict == "no data")
    }
}

@Suite("frameTimeStatistics: garbage samples")
struct FrameTimeSanitizationTests {

    @Test("non-finite and non-positive samples are dropped, not averaged in")
    func dropsGarbage() {
        // A display link's first delta is meaningless and a coalesced callback
        // can report 0. Either, left in, would drag the mean DOWN and understate
        // jank — the one direction this measurement must never fail in.
        let dirty: [Double] = [.nan, 0, -5, .infinity, 10, 20, 30]
        let clean = frameTimeStatistics(intervalsMs: [10, 20, 30])
        #expect(frameTimeStatistics(intervalsMs: dirty) == clean)
        #expect(frameTimeStatistics(intervalsMs: dirty).frameCount == 3)
    }

    @Test("an all-garbage run reports empty rather than NaN")
    func allGarbageIsEmpty() {
        // A NaN escaping into a comparison table would silently poison the
        // decision; an explicit zero row reads as "no data".
        #expect(frameTimeStatistics(intervalsMs: [.nan, 0, -1]) == .empty)
    }

    @Test("no statistic is ever NaN or infinite, whatever the input")
    func alwaysFinite() {
        let inputs: [[Double]] = [
            [], [0], [-1], [.nan], [.infinity], [1e-9], [1e9], [8, .nan, 16],
        ]
        for samples in inputs {
            let s = frameTimeStatistics(intervalsMs: samples)
            for value in [s.duration, s.meanMs, s.p50Ms, s.p95Ms, s.p99Ms, s.longestFrameMs] {
                #expect(value.isFinite)
            }
        }
    }
}

@Suite("frameTimeStatistics: degenerate inputs")
struct FrameTimeDegenerateTests {

    @Test("an empty run is the empty summary, not a crash")
    func empty() {
        #expect(frameTimeStatistics(intervalsMs: []) == .empty)
    }

    @Test("a single sample is every percentile, the mean and the max")
    func single() {
        let stats = frameTimeStatistics(intervalsMs: [42])
        #expect(stats.frameCount == 1)
        #expect(stats.meanMs == 42)
        #expect(stats.p50Ms == 42)
        #expect(stats.p95Ms == 42)
        #expect(stats.p99Ms == 42)
        #expect(stats.longestFrameMs == 42)
    }

    @Test("identical samples collapse every statistic to that value")
    func allIdentical() {
        let stats = frameTimeStatistics(intervalsMs: Array(repeating: 16.0, count: 37))
        #expect(stats.meanMs == 16)
        #expect(stats.p50Ms == 16)
        #expect(stats.p99Ms == 16)
        #expect(stats.longestFrameMs == 16)
        #expect(stats.hitches16Count == 0)   // 16 < 16.7
    }
}

@Suite("frameTimeStatistics: properties")
struct FrameTimePropertyTests {

    /// A spread of realistic runs: smooth, hitchy, and pathological.
    private static let runs: [[Double]] = [
        Array(repeating: 8.33, count: 300),
        (0..<300).map { $0 % 60 == 0 ? 45.0 : 8.33 },       // periodic band hitch
        (0..<300).map { _ in Double.random(in: 6...40) },
        (1...300).map(Double.init),
        [1, 1000],
    ]

    @Test("percentiles are ordered p50 ≤ p95 ≤ p99 ≤ longest")
    func percentilesOrdered() {
        for run in Self.runs {
            let s = frameTimeStatistics(intervalsMs: run)
            #expect(s.p50Ms <= s.p95Ms)
            #expect(s.p95Ms <= s.p99Ms)
            #expect(s.p99Ms <= s.longestFrameMs)
        }
    }

    @Test("the mean lies between the fastest and slowest frame")
    func meanWithinRange() {
        // Compared with a tolerance, not exactly: summing 300 identical doubles
        // accumulates rounding, so the mean of an all-8.33ms run lands a few ulps
        // BELOW 8.33 and a strict `>=` would fail on a correct result. The
        // property being pinned is "the mean is in range", not bit-exactness.
        let epsilon = 1e-9
        for run in Self.runs {
            let s = frameTimeStatistics(intervalsMs: run)
            #expect(s.meanMs <= s.longestFrameMs + epsilon)
            #expect(s.meanMs >= run.min()! - epsilon)
        }
    }

    @Test("the result is independent of sample order")
    func orderIndependent() {
        // Frames arrive in time order, but no statistic here may depend on that —
        // otherwise a run's numbers would change under an irrelevant reordering.
        for run in Self.runs {
            #expect(frameTimeStatistics(intervalsMs: run)
                == frameTimeStatistics(intervalsMs: run.shuffled()))
        }
    }

    @Test("duration equals the summed intervals, in seconds")
    func durationMatchesSum() {
        for run in Self.runs {
            let s = frameTimeStatistics(intervalsMs: run)
            #expect(abs(s.duration - run.reduce(0, +) / 1000) < 1e-9)
        }
    }
}
