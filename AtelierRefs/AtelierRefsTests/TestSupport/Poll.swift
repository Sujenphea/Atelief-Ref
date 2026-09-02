//
//  Poll.swift
//  AtelierRefsTests
//
//  099 · 11A — the one bounded wait, and the one place to change it.
//
//  There were eighteen private copies of this loop in this suite, under five
//  names (`settle` ×8, `waitUntil` ×5, `eventually` ×2, `poll`, `waitForDeparture`),
//  with iteration counts of 100, 200, 300, 400, 500 and 600 and three different
//  answers to "what happens on timeout": record an `Issue`, assert something else
//  afterwards, or return silently and let the next `#expect` take the blame.
//
//  This phase moves ONE of them here — `LibrarySearchModelTests`' `poll`, which
//  the plan names — plus the two copies `ThumbnailPipelineTests` had written
//  inline in the middle of a test body. The other fifteen are left alone
//  deliberately: they are correct, they are not what 11A is about, and a
//  sixteen-file rename would bury this phase's actual changes in a diff nobody
//  can read. What is written down here is where the next one should go.
//
//  **A poll is still second best.** Where the object under test can SAY it
//  finished — `DetailImageLoader.events`, `ThumbnailPipeline.events`,
//  `LibrarySearchModel.events`, `waitForPendingWork()` — await the signal; it is
//  exact, and it takes exactly as long as the work does. A poll is for state that
//  belongs to something with no seam to add one to.
//

import Foundation
import Testing

/// Wait until `condition` holds, or give up after `timeout`.
///
/// - Returns: whether the condition was met. `@discardableResult` because the
///   original caller ignored it and its following `#expect` is the real
///   assertion; a caller whose whole point is "this must have happened" should
///   `#expect(await poll { … })` and get a failure that names the wait rather
///   than the consequence.
///
/// Bounded, always. An unbounded wait in a test body stalls the whole runner with
/// `xcodebuild` at 0% CPU and no output — the failure mode `.change-log/330`
/// records costing nineteen minutes of a run.
@MainActor
@discardableResult
func poll(
    timeout: Duration = .seconds(3),
    interval: Duration = .milliseconds(10),
    until condition: @MainActor () -> Bool
) async -> Bool {
    if condition() { return true }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: interval)
        if condition() { return true }
    }
    return condition()
}
