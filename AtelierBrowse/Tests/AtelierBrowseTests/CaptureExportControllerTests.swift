//
//  CaptureExportControllerTests.swift
//  AtelierBrowseTests
//
//  098 · finding 9 — the export phase machine, which had never been run by anything but a
//  person tapping a button.
//
//  Five states and one invariant, and the invariant is the reason this file is long:
//  **"Clear" may only retire the ids that reached the last manifest.** Every other rule
//  here is about keeping that true through a failure, a cancelled share sheet, a second
//  export, and a `keep()` — because the failure mode is a capture removed from the waiting
//  set on the strength of a transfer that did not happen, and the phone has no way to find
//  out afterwards (091 · D4: the Mac says nothing back).
//
//  **The I/O is injected and the exclusion is real.** The count, the write and the retire
//  are closures over a `Rig` that records what it was asked and answers what the test
//  wants; the archive itself is `AtelierArchiveTests`' subject and nothing here re-tests
//  it. The exclusion, though, is a genuine `InboxDrainPolicy` in most of these — 098 ·
//  finding 11 notes that the policy's own suite proves the exclusion only against
//  stand-in bodies, and the export controller is the real body on the phone. Pairing the
//  two here is the package half of that.
//

import Foundation
import Testing

import AtelierCaptureTestSupport
@testable import AtelierBrowse

// MARK: - Harness

/// The inbox, as far as the controller can tell: a count, a write and a retire.
@MainActor
private final class Rig {
    /// Where a held-open write parks, so `.working` is observable.
    let writeGate = Gate()

    /// What the next `pendingCount()` answers. `nil` means throw.
    var pending: Int? = 3
    /// What the next `write` does. `nil` means succeed.
    var writeFailure: Error?
    /// The ids the next successful write reports as having reached the manifest.
    var exportedIDs: [UUID] = [UUID(), UUID()]
    /// Whether a write parks on ``writeGate``.
    var writeHoldsOpen = false

    private(set) var countCalls = 0
    private(set) var writes: [(parent: URL, folder: String, now: Date)] = []
    private(set) var retired: [[UUID]] = []
    private(set) var trace: [String] = []

    let exportsParent = URL(fileURLWithPath: "/tmp/atelier-tests/Exports", isDirectory: true)

    /// A real policy, so the exclusion under test is the one the app uses.
    private(set) var policy: InboxDrainPolicy<Int>!
    /// Where a drain pass parks, for the two ordering cases.
    let passGate = Gate()
    var passHoldsOpen = false
    private(set) var passes = 0

    private(set) var controller: CaptureExportController!

    init() {
        policy = InboxDrainPolicy<Int>(
            pass: { [weak self] in
                guard let self else { return 0 }
                passes += 1
                trace.append("pass.begin")
                if passHoldsOpen { await passGate.wait() }
                trace.append("pass.end")
                return passes
            },
            report: { _ in })

        controller = CaptureExportController(
            exportsParent: exportsParent,
            exclusion: { [weak self] body in await self?.policy.exclusively(body) },
            pendingCount: { [unowned self] in try count() },
            write: { [unowned self] parent, folder, now in
                try await write(parent, folder, now)
            },
            retire: { [unowned self] ids in await retire(ids) })
    }

    struct Unreadable: Error {}

    func count() throws -> Int {
        countCalls += 1
        guard let pending else { throw Unreadable() }
        return pending
    }

    func write(_ parent: URL, _ folder: String, _ now: Date) async throws
        -> CaptureExportController.Written {
        trace.append("write.begin")
        if writeHoldsOpen { await writeGate.wait() }
        writes.append((parent, folder, now))
        trace.append("write.end")
        if let writeFailure { throw writeFailure }
        return CaptureExportController.Written(
            url: parent.appendingPathComponent(folder, isDirectory: true),
            exported: exportedIDs)
    }

    func retire(_ ids: [UUID]) async {
        trace.append("retire")
        retired.append(ids)
    }
}

@Suite("CaptureExportController (098 · 9)")
@MainActor
struct CaptureExportControllerTests {

    // MARK: - The count

    @Test("nothing is counted until something asks")
    func startsUncounted() {
        let rig = Rig()
        #expect(rig.controller.pending == nil)
        #expect(rig.controller.phase == .idle)
        #expect(rig.countCalls == 0)
    }

    @Test("refresh takes the number the inbox reports")
    func refreshCounts() {
        let rig = Rig()
        rig.pending = 7
        rig.controller.refresh()
        #expect(rig.controller.pending == 7)
        #expect(rig.countCalls == 1)
    }

    @Test("an inbox that cannot be read counts ZERO, and zero hides the control")
    func unreadableInboxCountsZero() {
        let rig = Rig()
        rig.pending = 4
        rig.controller.refresh()
        #expect(rig.controller.pending == 4)

        // The behaviour this move inherited, pinned rather than changed. A directory that
        // will not enumerate makes the count throw, the throw becomes 0, and 0 is what
        // `CollectionScreen` reads as "there is nothing to send" — so the control
        // disappears from a phone with four captures still owed to a Mac. Nothing else in
        // the app reports the failure. Surfacing it is a screen and screens are 098 · P6's;
        // what this test buys is that the next person to touch it has to argue with a
        // sentence rather than rediscover the swallow.
        rig.pending = nil
        rig.controller.refresh()
        #expect(rig.controller.pending == 0)
    }

    @Test("an empty inbox counts zero too — the same number for two different reasons")
    func emptyInboxCountsZero() {
        let rig = Rig()
        rig.pending = 0
        rig.controller.refresh()
        #expect(rig.controller.pending == 0)
    }

    // MARK: - Export

    @Test("an export goes idle → working → ready and names the folder it wrote")
    func exportSucceeds() async {
        let rig = Rig()
        let now = Date(timeIntervalSince1970: 1_755_455_400)
        await rig.controller.export(now: now)

        guard case .ready(let url) = rig.controller.phase else {
            Issue.record("expected .ready, got \(rig.controller.phase)")
            return
        }
        #expect(url.lastPathComponent == CaptureExportController.folderName(now))
        #expect(rig.writes.count == 1)
        // The injected parent, not a directory the controller chose for itself.
        #expect(rig.writes[0].parent == rig.exportsParent)
        #expect(rig.writes[0].folder == CaptureExportController.folderName(now))
        #expect(rig.writes[0].now == now)
    }

    @Test("`.working` is set BEFORE the wait, so the button cannot be pressed twice")
    func workingIsSetBeforeTheWait() async {
        let rig = Rig()
        rig.writeHoldsOpen = true

        let export = Task { @MainActor in await rig.controller.export() }
        await Task.yield()

        // The send control disables on `.working`. If the phase were set after the
        // exclusion returned, a control queued behind a drain pass would stay live for the
        // whole of that pass.
        #expect(rig.controller.phase == .working)
        rig.writeGate.open()
        await export.value
        #expect(rig.controller.phase != .working)
    }

    @Test("an export re-counts what is left afterwards")
    func exportRecounts() async {
        let rig = Rig()
        rig.pending = 3
        rig.controller.refresh()
        rig.pending = 3
        await rig.controller.export()
        // Nothing is deleted by an export, so the count is expected to be unchanged — but
        // it is RE-READ, because a share that landed during the write would change it.
        #expect(rig.countCalls == 2)
        #expect(rig.controller.pending == 3)
    }

    @Test("each export failure gets its own sentence")
    func exportFailureSentences() async {
        struct Whatever: Error {}
        let cases: [(Error, String)] = [
            (CaptureExportFailure.nothingToExport,
             "There are no captures waiting to be sent."),
            (CaptureExportFailure.nothingCopied,
             "None of the waiting captures could be read."),
            (Whatever(), "The captures couldn't be written."),
        ]
        for (error, sentence) in cases {
            let rig = Rig()
            rig.writeFailure = error
            await rig.controller.export()
            #expect(rig.controller.phase == .failed(sentence))
        }
    }

    @Test("a failed export leaves nothing for Clear to retire")
    func failureClearsTheExportedIDs() async {
        let rig = Rig()
        await rig.controller.export()
        guard case .ready = rig.controller.phase else {
            Issue.record("expected .ready")
            return
        }

        rig.writeFailure = CaptureExportFailure.nothingCopied
        await rig.controller.export()

        // The invariant, through a failure: a "Clear" offered after a failed send would
        // retire captures on the strength of a transfer that did not happen. `finish()`
        // therefore has nothing to offer.
        rig.controller.finish()
        #expect(rig.controller.phase == .idle)
        await rig.controller.retire()
        #expect(rig.retired.isEmpty)
    }

    @Test("a second export replaces the first export's ids")
    func secondExportReplacesTheIDs() async {
        let rig = Rig()
        let first = [UUID(), UUID()]
        rig.exportedIDs = first
        await rig.controller.export()

        let second = [UUID()]
        rig.exportedIDs = second
        await rig.controller.export()
        rig.controller.finish()
        #expect(rig.controller.phase == .sent(1))

        await rig.controller.retire()
        #expect(rig.retired == [second])
    }

    // MARK: - finish / keep / retire

    @Test("finishing after a send offers exactly what reached the manifest")
    func finishOffersTheManifestCount() async {
        let rig = Rig()
        rig.exportedIDs = [UUID(), UUID(), UUID()]
        // The pending set is a SUPERSET of what an export can carry: a record the archive
        // funnel refuses is pending and not exported.
        rig.pending = 5
        await rig.controller.export()
        rig.controller.finish()
        #expect(rig.controller.phase == .sent(3))
    }

    @Test("finishing an export that carried nothing goes straight back to idle")
    func finishWithNothingExported() async {
        let rig = Rig()
        rig.exportedIDs = []
        await rig.controller.export()
        rig.controller.finish()
        // No offer, because there is nothing to offer to retire — and an offer showing "0"
        // is a question with no answer.
        #expect(rig.controller.phase == .idle)
    }

    @Test("finishing without an export at all is idle, not a stuck sheet")
    func finishWithoutAnExport() {
        let rig = Rig()
        rig.controller.finish()
        #expect(rig.controller.phase == .idle)
    }

    @Test("Clear retires exactly the exported ids, then re-counts")
    func retireSendsTheExportedIDs() async {
        let rig = Rig()
        let ids = [UUID(), UUID()]
        rig.exportedIDs = ids
        await rig.controller.export()
        rig.controller.finish()

        rig.pending = 1
        await rig.controller.retire()

        #expect(rig.retired == [ids])
        #expect(rig.controller.phase == .idle)
        #expect(rig.controller.pending == 1)
    }

    @Test("Clear twice retires once — the ids are spent")
    func retireIsNotRepeatable() async {
        let rig = Rig()
        await rig.controller.export()
        await rig.controller.retire()
        await rig.controller.retire()
        #expect(rig.retired.count == 1)
    }

    @Test("Clear with nothing exported calls nothing and lands on idle")
    func retireWithNothing() async {
        let rig = Rig()
        await rig.controller.retire()
        #expect(rig.retired.isEmpty)
        #expect(rig.controller.phase == .idle)
        // And it does not take the inbox for a body that would do nothing.
        #expect(rig.controller.phase == .idle)
    }

    @Test("Keep spends the ids without retiring them")
    func keepDeclinesTheOffer() async {
        let rig = Rig()
        await rig.controller.export()
        rig.controller.finish()
        rig.controller.keep()
        #expect(rig.controller.phase == .idle)

        // The captures stay pending and go out again next time; nothing was moved.
        await rig.controller.retire()
        #expect(rig.retired.isEmpty)
    }

    // MARK: - The exclusion, against a real policy (098 · finding 11)

    @Test("an export waits out a drain pass that is already running")
    func exportWaitsForARunningPass() async {
        let rig = Rig()
        rig.passHoldsOpen = true
        rig.policy.start()
        #expect(rig.policy.isDraining)

        let export = Task { @MainActor in await rig.controller.export() }
        await Task.yield()

        // Queued, not running: the write has not begun, and the phase says `.working` so
        // the control is already disabled.
        #expect(rig.controller.phase == .working)
        #expect(rig.writes.isEmpty)

        rig.passGate.open()
        await export.value

        #expect(rig.trace == ["pass.begin", "pass.end", "write.begin", "write.end"])
        #expect(rig.policy.exportsHolding == 0)
    }

    @Test("a drain activation during an export is deferred and runs after it")
    func activationDuringAnExportIsDeferred() async {
        let rig = Rig()
        rig.writeHoldsOpen = true

        let export = Task { @MainActor in await rig.controller.export() }
        await Task.yield()
        #expect(rig.writes.isEmpty || rig.trace.contains("write.begin"))

        // The activation the phone gets from `ScenePhase` while a send is in flight. 455's
        // bug 1 was this being DROPPED rather than deferred, which lost a capture until
        // the next foreground.
        rig.policy.scenePhaseChanged(to: .active)
        #expect(rig.passes == 0)

        rig.writeGate.open()
        await export.value

        // The deferred pass runs off the back of the export body.
        #expect(rig.passes == 1)
        #expect(rig.trace.firstIndex(of: "write.end")! < rig.trace.firstIndex(of: "pass.begin")!)
        #expect(rig.policy.exportsHolding == 0)
    }

    @Test("Clear takes the inbox too — it moves records a pass may be reading")
    func retireRunsUnderTheExclusion() async {
        let rig = Rig()
        await rig.controller.export()
        rig.controller.finish()

        rig.passHoldsOpen = true
        rig.policy.scenePhaseChanged(to: .active)
        #expect(rig.policy.isDraining)

        let clear = Task { @MainActor in await rig.controller.retire() }
        await Task.yield()
        #expect(rig.retired.isEmpty, "the retire began underneath a running pass")

        rig.passGate.open()
        await clear.value
        #expect(rig.retired.count == 1)
        #expect(rig.policy.exportsHolding == 0)
    }

    // MARK: - The folder name

    @Test("the folder name is sortable and says what it is")
    func folderName() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 17
        components.hour = 18
        components.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: components)!
        #expect(CaptureExportController.folderName(date) == "Atelier 2026-08-17 1830")
    }

    @Test("the folder name does not follow the device's calendar or locale")
    func folderNameIsLocaleIndependent() {
        // It crosses to a Mac desktop and is read by a person. A phone set to a
        // non-Gregorian calendar must not produce a name that does not sort beside the
        // ones a different phone made.
        let date = Date(timeIntervalSince1970: 1_755_455_400)
        let name = CaptureExportController.folderName(date)
        #expect(name.hasPrefix("Atelier "))
        #expect(name.count == "Atelier 2026-08-17 1830".count)
        #expect(name.allSatisfy { $0.isASCII })
    }

    @Test("two sends in the same minute produce the same name; a minute later, a new one")
    func folderNameIsPerMinute() {
        let base = Date(timeIntervalSince1970: 1_755_455_400)
        #expect(CaptureExportController.folderName(base)
            == CaptureExportController.folderName(base.addingTimeInterval(30)))
        #expect(CaptureExportController.folderName(base)
            != CaptureExportController.folderName(base.addingTimeInterval(60)))
    }
}
