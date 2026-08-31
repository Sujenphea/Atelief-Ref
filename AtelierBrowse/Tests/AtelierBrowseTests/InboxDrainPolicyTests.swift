//
//  InboxDrainPolicyTests.swift
//  AtelierBrowseTests
//
//  096 · 4, phase 4 — the cadence the drain deliberately does not own, and the
//  mutual exclusion the phone needs and the Mac does not.
//
//  Phase 3's changelog closed on this:
//
//    > The three properties the design turns on — an activation dropped while a pass
//    > runs, an export waiting out a running pass, and a deferred activation running
//    > after an export — are asserted by construction and by the build, and by nothing
//    > else.
//
//  This file is the "and by nothing else" being retired. Every rule the header of
//  `InboxDrainPolicy` argues for is stated here as a test, in both orders where there
//  are two.
//
//  **Why the pass is injected, and why it parks.** A real `InboxDrain.drainOnce()` over
//  a real directory finishes in microseconds, so "two activations did not overlap"
//  could only ever be asserted by luck. Here a pass parks on a gate the test opens, so
//  the overlapping case is the deterministic one rather than the rare one. What a pass
//  DOES to records is `AtelierIngestionTests`' subject against real files; nothing here
//  re-tests it — which is also why the outcome type is `Int` and not `DrainSummary`.
//  The policy is generic over that type precisely so it can be, and using the simplest
//  possible stand-in is the assertion that it really does not look inside.
//
//  **Ordering is asserted on a trace, not on sleeps.** Every pass, report, export body
//  and dropped activation appends a line to `Rig.trace`, and the serialization claims
//  are "this line came before that one" over that array. A test that slept and then
//  looked at a counter would pass on a machine that happened to be slow.
//

import Foundation
import Testing

@testable import AtelierBrowse

// MARK: - Harness

/// A gate any number of bodies can park on, opened once. `open()` is idempotent and may
/// be called before `wait()`, so a test never has to sequence the two.
@MainActor
private final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

/// A policy over a counting pass, plus the knobs a test drives it with.
@MainActor
private final class Rig {
    /// Where a held-open pass parks.
    let gate = Gate()
    /// Where a held-open export body parks. A second gate, so a test can release a pass
    /// and an export independently — which is the whole point of the ordering cases.
    let exportGate = Gate()

    /// How many passes have STARTED. Incremented before the gate, so it counts entries
    /// rather than completions.
    private(set) var passes = 0
    /// How many passes have RETURNED.
    private(set) var completedPasses = 0
    /// What ``InboxDrainPolicy`` handed back, in the order it handed it back.
    private(set) var reported: [Int] = []
    /// The activations that did not become passes.
    private(set) var events: [InboxDrainEvent] = []
    /// Everything above, interleaved, in the order it happened.
    private(set) var trace: [String] = []

    /// What each successive pass returns; the last value repeats once exhausted.
    var outcomes: [Int] = [0]
    /// Whether a pass parks on ``gate``. Off by default so most cases run straight
    /// through with no sequencing at all.
    var holdsOpen = false
    /// Run inside the report callback, once per pass. Where the re-entrancy cases live.
    var onReport: ((Int) -> Void)?

    private(set) var policy: InboxDrainPolicy<Int>!

    /// - Parameter observed: whether an `observe:` hook is installed at all. One case
    ///   builds a policy without one, to pin that the hook is an observation and not a
    ///   part of the policy.
    init(observed: Bool = true) {
        var observe: (@MainActor (InboxDrainEvent) -> Void)?
        if observed {
            observe = { [weak self] event in
                guard let self else { return }
                events.append(event)
                trace.append("event \(event)")
            }
        }
        policy = InboxDrainPolicy(
            pass: { [weak self] in
                guard let self else { return -1 }
                let index = passes
                passes += 1
                trace.append("pass \(index) start")
                if holdsOpen { await gate.wait() }
                completedPasses += 1
                trace.append("pass \(index) end")
                return outcomes[min(index, outcomes.count - 1)]
            },
            report: { [weak self] outcome in
                guard let self else { return }
                reported.append(outcome)
                trace.append("report \(outcome)")
                onReport?(outcome)
            },
            observe: observe)
    }

    // MARK: Driving

    /// Start an export that holds the inbox, without waiting for it. Returns the task so
    /// a case can await the whole thing once it has asserted what it wanted to.
    ///
    /// - Parameter parks: whether the body waits on ``exportGate`` before returning.
    @discardableResult
    func startExport(_ label: String, parks: Bool = false) -> Task<Void, Never> {
        Task { @MainActor in
            await policy.exclusively { [weak self] in
                guard let self else { return }
                trace.append("\(label) start")
                if parks { await exportGate.wait() }
                trace.append("\(label) end")
            }
        }
    }

    /// Let a parked pass finish and settle whatever it kicked off.
    func settle() async {
        gate.open()
        await policy.inFlight?.value
        // A report that re-drained leaves a second task behind; drain the chain.
        while let holder = policy.inFlight { await holder.value }
    }

    /// Poll until `condition` holds — a pass is an unstructured `Task`, so there is no
    /// chain to await before it has been claimed.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    /// Give anything that was going to happen a chance to happen. Used only for the
    /// NEGATIVE assertions ("and then nothing else ran"), where there is by definition
    /// no state change to wait for.
    func quiesce() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    // MARK: Asserting

    /// Append a line to the trace from outside the rig's own closures — the two failure
    /// cases build a policy by hand and still want their reports in the same order-preserving
    /// place everything else is in.
    func note(_ line: String) { trace.append(line) }

    func happened(_ line: String) -> Bool { trace.contains(line) }

    /// `first` appears in the trace, `second` appears in the trace, and `first` is
    /// earlier. All three, so a missing line fails rather than vacuously passing.
    func happened(_ first: String, before second: String) -> Bool {
        guard let a = trace.firstIndex(of: first), let b = trace.firstIndex(of: second)
        else { return false }
        return a < b
    }

    func count(of line: String) -> Int { trace.filter { $0 == line }.count }

    /// The most bodies from `labels` that were ever open at the same time, over the trace.
    ///
    /// **This, and not "a ran before b", is what serialization means here.** Two exports
    /// parked on one drain pass are resumed by the same task completing, and the order the
    /// runtime wakes two continuations in is not something a policy can promise or a test
    /// should assert. What it can promise is that the second body does not begin until the
    /// first has ended, whichever of them went first.
    func maxOverlap(of labels: [String]) -> Int {
        var open = 0
        var highest = 0
        for line in trace {
            guard let label = labels.first(where: {
                line == "\($0) start" || line == "\($0) end"
            }) else { continue }
            open += line == "\(label) start" ? 1 : -1
            highest = max(highest, open)
        }
        return highest
    }
}

// MARK: - Launch

@MainActor
@Suite("InboxDrainPolicy: launch and idempotence (096 · 4)")
struct InboxDrainPolicyLaunchTests {

    @Test("nothing runs until start() is called")
    func dormantUntilStarted() async {
        let rig = Rig()
        await rig.quiesce()
        #expect(rig.passes == 0)
        #expect(rig.policy.isDraining == false)
        #expect(rig.policy.inFlight == nil)
    }

    @Test("start() runs exactly one pass")
    func launchDrains() async {
        let rig = Rig()
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        #expect(rig.passes == 1)
        #expect(rig.completedPasses == 1)
    }

    @Test("a second start() is a no-op, not a second pass")
    func startIsIdempotent() async {
        let rig = Rig()
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()

        rig.policy.start()
        rig.policy.start()
        await rig.quiesce()
        // A view's `task` re-running must not drain again. The Mac's equivalent case is
        // about a second notification subscription; here it is about a second pass.
        #expect(rig.passes == 1)
    }

    @Test("start() while a pass is already in flight neither doubles nor is forgotten")
    func startDuringPassIsSwallowedButStillCounts() async {
        let rig = Rig()
        rig.holdsOpen = true
        // An activation beat the launch to it — a real possibility, since the scene can
        // become active before `bootstrap()` returns.
        rig.policy.drain()
        #expect(await rig.waitUntil { rig.passes == 1 })

        rig.policy.start()
        await rig.quiesce()
        // Dropped by the overlap guard, exactly as any other activation would be.
        #expect(rig.passes == 1)
        #expect(rig.events == [.activationDroppedDuringPass])

        await rig.settle()
        // And still marked as started: the launch pass is not re-attempted later, because
        // the pass that swallowed it re-enumerated the same directory.
        rig.policy.start()
        await rig.quiesce()
        #expect(rig.passes == 1)
    }

    @Test("start() after a completed pass is still a no-op")
    func startAfterCompletionIsStillIdempotent() async {
        let rig = Rig()
        rig.policy.start()
        #expect(await rig.waitUntil { rig.completedPasses == 1 })
        await rig.settle()
        rig.policy.start()
        await rig.quiesce()
        #expect(rig.passes == 1)
    }
}

// MARK: - Scene phase

@MainActor
@Suite("InboxDrainPolicy: active, and only active (096 · 4)")
struct InboxDrainPolicyPhaseTests {

    @Test("becoming active runs a pass")
    func activeDrains() async {
        let rig = Rig()
        rig.policy.scenePhaseChanged(to: .active)
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
    }

    @Test("every other phase runs nothing", arguments: [ScenePhaseKind.inactive, .background])
    func otherPhasesDoNothing(phase: ScenePhaseKind) async {
        let rig = Rig()
        rig.policy.scenePhaseChanged(to: phase)
        await rig.quiesce()
        #expect(rig.passes == 0)
        #expect(rig.policy.isDraining == false)
    }

    @Test("exactly one of the three phases drains")
    func onlyOneCaseDrains() async {
        // Over `allCases`, so a phase added to the mirror later has to be reasoned about
        // rather than silently inheriting "does nothing" — or, worse, "drains".
        var draining: [ScenePhaseKind] = []
        for phase in ScenePhaseKind.allCases {
            let rig = Rig()
            rig.policy.scenePhaseChanged(to: phase)
            if await rig.waitUntil(timeout: 0.3, { rig.passes == 1 }) {
                draining.append(phase)
                await rig.settle()
            }
        }
        #expect(draining == [.active])
    }

    @Test("repeated activations each drain when nothing is in flight")
    func repeatedActivationsDrain() async {
        let rig = Rig()
        for _ in 0..<3 {
            rig.policy.scenePhaseChanged(to: .active)
            #expect(await rig.waitUntil { rig.policy.inFlight != nil })
            await rig.settle()
        }
        #expect(rig.passes == 3)
        #expect(rig.reported.count == 3)
    }

    @Test("a background/foreground round trip drains once, on the way in")
    func roundTripDrainsOnce() async {
        let rig = Rig()
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()

        rig.policy.scenePhaseChanged(to: .inactive)
        rig.policy.scenePhaseChanged(to: .background)
        await rig.quiesce()
        #expect(rig.passes == 1)

        rig.policy.scenePhaseChanged(to: .inactive)
        await rig.quiesce()
        #expect(rig.passes == 1)

        rig.policy.scenePhaseChanged(to: .active)
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()
    }
}

// MARK: - Overlap

@MainActor
@Suite("InboxDrainPolicy: one pass at a time (096 · 4)")
struct InboxDrainPolicyOverlapTests {

    @Test("an activation during a running pass does NOT start a second one")
    func activationDuringPassIsDropped() async {
        let rig = Rig()
        rig.holdsOpen = true
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        #expect(rig.policy.isDraining)

        // Three activations while the first pass is parked mid-flight. All three must be
        // dropped, not queued — the running pass re-enumerates the directory anyway.
        for _ in 0..<3 { rig.policy.scenePhaseChanged(to: .active) }
        await rig.quiesce()
        #expect(rig.passes == 1)
        #expect(rig.events == Array(repeating: .activationDroppedDuringPass, count: 3))

        await rig.settle()
        #expect(rig.policy.isDraining == false)
        // And still one: a dropped activation is dropped, not deferred. This is the half
        // that distinguishes it from an activation dropped during an export.
        #expect(rig.passes == 1)
    }

    @Test("a dropped activation produces no report")
    func droppedActivationDoesNotReport() async {
        let rig = Rig()
        rig.holdsOpen = true
        rig.outcomes = [7]
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        rig.policy.drain()
        rig.policy.drain()
        await rig.settle()
        #expect(rig.reported == [7])
    }

    @Test("the guard is not a latch: activating after a pass finishes drains again")
    func guardReleasesAfterPass() async {
        let rig = Rig()
        rig.holdsOpen = true
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        rig.policy.drain()
        #expect(rig.passes == 1)

        await rig.settle()
        #expect(rig.policy.isDraining == false)

        // The gate is open now, so this one runs straight through.
        rig.policy.drain()
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()
    }

    @Test("inFlight is claimed synchronously, before the pass body has run")
    func gateClosesWithoutSuspending() {
        let rig = Rig()
        rig.holdsOpen = true
        rig.policy.drain()
        // No await between these two lines: the read that decides and the write that
        // claims are one step, which is the whole reason the type is `@MainActor`. If the
        // claim happened inside the task body instead, a second `drain()` here would win.
        #expect(rig.policy.isDraining)
        rig.policy.drain()
        #expect(rig.passes == 0, "the pass body has not been entered yet")
        #expect(rig.events == [.activationDroppedDuringPass])
    }

    @Test("the observe hook is optional and changes no decision")
    func observeIsNotPolicy() async {
        let rig = Rig(observed: false)
        rig.holdsOpen = true
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        rig.policy.drain()
        rig.policy.drain()
        await rig.quiesce()
        #expect(rig.passes == 1)
        #expect(rig.events.isEmpty)
        await rig.settle()
        #expect(rig.passes == 1)
    }
}

// MARK: - The report

@MainActor
@Suite("InboxDrainPolicy: what a pass reported (096 · 4)")
struct InboxDrainPolicyReportTests {

    @Test("each pass reports exactly once, with its own outcome, in order")
    func reportsInOrder() async {
        let rig = Rig()
        rig.outcomes = [11, 22, 33]
        for _ in 0..<3 {
            rig.policy.drain()
            #expect(await rig.waitUntil { rig.policy.inFlight != nil })
            await rig.settle()
        }
        #expect(rig.reported == [11, 22, 33])
    }

    @Test("the last outcome repeats once the script is exhausted")
    func outcomesRepeat() async {
        let rig = Rig()
        rig.outcomes = [5]
        for _ in 0..<2 {
            rig.policy.drain()
            #expect(await rig.waitUntil { rig.policy.inFlight != nil })
            await rig.settle()
        }
        #expect(rig.reported == [5, 5])
    }

    @Test("the report runs after the pass, not during it")
    func reportFollowsPass() async {
        let rig = Rig()
        rig.outcomes = [9]
        rig.policy.drain()
        await rig.settle()
        #expect(rig.happened("pass 0 end", before: "report 9"))
    }

    @Test("the inbox is released BEFORE the report — a report may start the next pass")
    func reportRunsWithTheInboxFree() async {
        let rig = Rig()
        var redrained = false
        rig.onReport = { [weak rig] _ in
            guard let rig, !redrained else { return }
            redrained = true
            // The app's report bumps a counter that every grid re-reads on. If the inbox
            // were still held here, a UI reaction that asked for a pass would be silently
            // swallowed — and the reason `inFlight` is cleared first would be invisible.
            #expect(rig.policy.isDraining == false)
            rig.policy.drain()
        }
        rig.policy.drain()
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()
        #expect(rig.passes == 2)
        #expect(rig.reported.count == 2)
    }
}

// MARK: - The inbox, exclusively

@MainActor
@Suite("InboxDrainPolicy: an export takes the inbox (096 · 4)")
struct InboxDrainPolicyExclusionTests {

    @Test("an export over an idle inbox runs immediately")
    func exportWithNothingInFlight() async {
        let rig = Rig()
        await rig.startExport("export").value
        #expect(rig.happened("export start", before: "export end"))
        #expect(rig.passes == 0)
        #expect(rig.policy.inFlight == nil)
    }

    @Test("the inbox is held for the duration of an export body")
    func exportHoldsTheInbox() async {
        let rig = Rig()
        let export = rig.startExport("export", parks: true)
        #expect(await rig.waitUntil { rig.happened("export start") })
        #expect(rig.policy.isDraining, "an export in flight holds the inbox")
        rig.exportGate.open()
        await export.value
        #expect(rig.policy.inFlight == nil, "and lets go of it afterwards")
    }

    // MARK: drain first, then export

    @Test("an export waits out a pass that is already running")
    func exportWaitsForARunningPass() async {
        let rig = Rig()
        rig.holdsOpen = true
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })

        let export = rig.startExport("export")
        await rig.quiesce()
        // The archive write must not begin while a pass can still move a record out from
        // under a payload it has already resolved.
        #expect(rig.happened("export start") == false)

        rig.gate.open()
        await export.value
        #expect(rig.happened("pass 0 end", before: "export start"))
        #expect(rig.happened("export start", before: "export end"))
    }

    // MARK: export first, then drain

    @Test("a pass does not start while an export holds the inbox")
    func passWaitsForAnExport() async {
        let rig = Rig()
        let export = rig.startExport("export", parks: true)
        #expect(await rig.waitUntil { rig.happened("export start") })

        rig.policy.scenePhaseChanged(to: .active)
        await rig.quiesce()
        #expect(rig.passes == 0)
        // DEFERRED, not dropped. This is the regression case for the guard order: an
        // export body has claimed `inFlight`, so asking `inFlight` first answered
        // "something is running, drop it" for the entire duration of an archive write.
        #expect(rig.events == [.activationDeferredDuringExport])

        rig.exportGate.open()
        await export.value
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        #expect(rig.happened("export end", before: "pass 0 start"))
    }

    @Test("a missed activation runs ONCE afterwards, not once per activation")
    func missedActivationRunsOnce() async {
        let rig = Rig()
        let export = rig.startExport("export", parks: true)
        #expect(await rig.waitUntil { rig.happened("export start") })

        // Five foregroundings while an AirDrop is in progress — the share sheet coming and
        // going is exactly this. One pass is owed, not five: the pass re-enumerates.
        for _ in 0..<5 { rig.policy.scenePhaseChanged(to: .active) }
        #expect(rig.events.count == 5)

        rig.exportGate.open()
        await export.value
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        await rig.quiesce()
        #expect(rig.passes == 1)
    }

    @Test("no activation during an export means no pass after it")
    func noSpuriousPassAfterExport() async {
        let rig = Rig()
        await rig.startExport("export").value
        await rig.quiesce()
        // The deferral is a memory of something that happened, not a habit.
        #expect(rig.passes == 0)
        #expect(rig.events.isEmpty)
    }

    @Test("the deferred pass runs after the export BODY, not merely after its wait")
    func deferredPassFollowsTheBody() async {
        let rig = Rig()
        let export = rig.startExport("export", parks: true)
        #expect(await rig.waitUntil { rig.happened("export start") })
        rig.policy.drain()
        rig.exportGate.open()
        await export.value
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        #expect(rig.happened("export end", before: "pass 0 start"))
    }

    @Test("the memory is one-shot: a second export does not replay the first's activation")
    func deferralDoesNotRepeat() async {
        let rig = Rig()
        let first = rig.startExport("a", parks: true)
        #expect(await rig.waitUntil { rig.happened("a start") })
        rig.policy.drain()
        rig.exportGate.open()
        await first.value
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()

        await rig.startExport("b").value
        await rig.quiesce()
        #expect(rig.passes == 1)
    }

    // MARK: two exports

    @Test("two exports serialize: the second body waits for the first")
    func exportsSerialize() async {
        let rig = Rig()
        let first = rig.startExport("a", parks: true)
        #expect(await rig.waitUntil { rig.happened("a start") })
        let second = rig.startExport("b")
        await rig.quiesce()
        #expect(rig.happened("b start") == false)

        rig.exportGate.open()
        await first.value
        await second.value
        #expect(rig.happened("a end", before: "b start"))
    }

    @Test("an activation cannot slip between two exports")
    func noPassBetweenTwoExports() async {
        let rig = Rig()
        let first = rig.startExport("a", parks: true)
        #expect(await rig.waitUntil { rig.happened("a start") })
        let second = rig.startExport("b")
        // Deferred, because `exportsHolding` is 2 — the count is what makes this correct.
        // A `Bool` cleared by the first export to finish would let this pass run between
        // the two bodies.
        #expect(await rig.waitUntil { rig.policy.exportsHolding == 2 })
        rig.policy.drain()
        #expect(rig.events == [.activationDeferredDuringExport])

        rig.exportGate.open()
        await first.value
        await second.value
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        #expect(rig.happened("a end", before: "b start"))
        #expect(rig.happened("b end", before: "pass 0 start"))
    }

    @Test("a pass, then two exports queued behind it, then the deferred pass")
    func passThenTwoExportsThenTheDeferredPass() async {
        let rig = Rig()
        rig.holdsOpen = true
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })

        let first = rig.startExport("a")
        let second = rig.startExport("b")
        // Both exports have claimed their place in the queue and are waiting on the
        // running pass. An activation now is DEFERRED rather than dropped: by the time
        // these two are done the pass that would have inherited it is long gone.
        #expect(await rig.waitUntil { rig.policy.exportsHolding == 2 })
        rig.policy.drain()
        #expect(rig.events == [.activationDeferredDuringExport])

        rig.gate.open()
        await first.value
        await second.value
        // The second pass runs off the deferral, not off a fresh activation. Holding the
        // gate open means it runs straight through.
        #expect(await rig.waitUntil { rig.passes == 2 })
        await rig.settle()
        // Neither export began before the pass finished, they did not overlap each other,
        // and the deferred pass came after both. Which of the two went first is the
        // runtime's business — see `maxOverlap(of:)`.
        #expect(rig.happened("pass 0 end", before: "a start"))
        #expect(rig.happened("pass 0 end", before: "b start"))
        #expect(rig.maxOverlap(of: ["a", "b"]) == 1)
        #expect(rig.happened("a end", before: "pass 1 start"))
        #expect(rig.happened("b end", before: "pass 1 start"))
        #expect(rig.passes == 2)
        #expect(rig.policy.exportsHolding == 0)
    }

    @Test("two exports overlapping do not live-lock the main actor")
    func twoExportsDoNotSpin() async {
        // The regression case for the release-from-inside fix. Phase 3's export cleared
        // `inFlight` AFTER awaiting its task, so a second export woken first could spin on
        // a finished task without ever yielding to the first — 100% of a core, forever.
        // What makes this reliable rather than lucky is that both exports are genuinely
        // queued (`exportsHolding == 2`) before either is allowed to finish.
        let rig = Rig()
        let first = rig.startExport("a", parks: true)
        let second = rig.startExport("b")
        #expect(await rig.waitUntil { rig.policy.exportsHolding == 2 })
        #expect(rig.happened("a start"))

        rig.exportGate.open()
        // If the loop spins, neither of these ever returns and the case times out rather
        // than failing — which is the honest failure mode for a live-lock.
        await first.value
        await second.value
        #expect(rig.happened("a end", before: "b start"))
        #expect(rig.count(of: "b end") == 1)
        #expect(rig.policy.exportsHolding == 0)
        #expect(rig.policy.inFlight == nil)
    }

    @Test("the holder count returns to zero", arguments: [1, 2, 5])
    func exportCountBalances(exports: Int) async {
        // The `defer` in `exclusively(_:)` exists because this counter going out of
        // balance fails nothing loudly — it silently stops the phone draining for the rest
        // of the launch. So it is asserted rather than reasoned about.
        let rig = Rig()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<exports { tasks.append(rig.startExport("e\(index)")) }
        for task in tasks { await task.value }
        #expect(rig.policy.exportsHolding == 0)
        // And the proof that zero MEANS something: a drain can start again.
        rig.policy.drain()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
    }

    @Test("the inbox is free again after an export, and a later activation drains")
    func exclusionIsNotALatch() async {
        let rig = Rig()
        await rig.startExport("export").value
        #expect(rig.policy.inFlight == nil)
        rig.policy.scenePhaseChanged(to: .active)
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
        #expect(rig.passes == 1)
    }

    @Test("exclusively(_:) returns only after its body has finished")
    func exclusivelyAwaitsItsBody() async {
        let rig = Rig()
        var finished = false
        await rig.policy.exclusively {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
            finished = true
        }
        #expect(finished)
    }

    @Test("ten exports and ten activations interleaved leave no overlap and no leak")
    func manyExportsAndActivations() async {
        let rig = Rig()
        var exports: [Task<Void, Never>] = []
        for index in 0..<10 {
            exports.append(rig.startExport("e\(index)"))
            rig.policy.drain()
        }
        for export in exports { await export.value }
        _ = await rig.waitUntil { rig.policy.inFlight == nil && rig.passes > 0 }
        await rig.settle()
        await rig.quiesce()
        #expect(rig.policy.exportsHolding == 0)
        // Every export body ran exactly once…
        for index in 0..<10 { #expect(rig.count(of: "e\(index) end") == 1) }
        // …and no two bodies were ever open at once.
        #expect(rig.maxOverlap(of: (0..<10).map { "e\($0)" }) == 1)
        #expect(rig.passes >= 1, "the deferred activation was not lost")
        #expect(rig.policy.inFlight == nil)
    }
}

// MARK: - Failure

@MainActor
@Suite("InboxDrainPolicy: a pass that went wrong (096 · 4)")
struct InboxDrainPolicyFailureTests {

    /// A pass whose work throws. `InboxDrain.drainOnce()` is `async` and NOT `throws` — it
    /// reports an unreadable inbox in its summary rather than propagating — so the throw
    /// is caught at the seam, which is exactly where the app catches it. What is being
    /// pinned is that the policy's bookkeeping survives it.
    private struct Boom: Error {}

    @Test("a pass whose work throws still releases the inbox")
    func throwingPassReleasesTheInbox() async {
        let rig = Rig()
        let policy = InboxDrainPolicy<Int>(
            pass: {
                do { throw Boom() } catch { return -1 }
            },
            report: { [weak rig] outcome in rig?.note("report \(outcome)") })
        policy.drain()
        _ = await rig.waitUntil { policy.inFlight == nil && rig.happened("report -1") }
        #expect(policy.isDraining == false)

        // And the next activation drains: a failed pass is not a latch.
        policy.drain()
        _ = await rig.waitUntil { rig.count(of: "report -1") == 2 }
        #expect(rig.count(of: "report -1") == 2)
    }

    @Test("a pass cancelled mid-flight still releases the inbox")
    func cancelledPassReleasesTheInbox() async {
        let rig = Rig()
        let policy = InboxDrainPolicy<Int>(
            pass: {
                // A real drain checks `Task.isCancelled` between chunks and returns what
                // it has. The property under test is the same either way: the task ends,
                // so `inFlight` clears.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return Task.isCancelled ? -2 : 0
            },
            report: { [weak rig] outcome in rig?.note("report \(outcome)") })
        policy.drain()
        #expect(policy.isDraining)
        policy.inFlight?.cancel()
        if let task = policy.inFlight { await task.value }
        #expect(rig.happened("report -2"))
        #expect(policy.isDraining == false)

        policy.drain()
        #expect(policy.isDraining)
        if let task = policy.inFlight { await task.value }
    }

    @Test("an export whose body does nothing still hands the inbox back")
    func emptyExportReleasesTheInbox() async {
        let rig = Rig()
        await rig.policy.exclusively {}
        #expect(rig.policy.inFlight == nil)
        rig.policy.drain()
        #expect(await rig.waitUntil { rig.passes == 1 })
        await rig.settle()
    }

    @Test("a hundred activations against a parked pass cost exactly one pass")
    func floodIsCoalesced() async {
        let rig = Rig()
        rig.holdsOpen = true
        rig.policy.start()
        #expect(await rig.waitUntil { rig.passes == 1 })
        for _ in 0..<100 { rig.policy.scenePhaseChanged(to: .active) }
        #expect(rig.passes == 1)
        #expect(rig.events.count == 100)
        await rig.settle()
        await rig.quiesce()
        #expect(rig.passes == 1)
        #expect(rig.reported.count == 1)
    }
}
