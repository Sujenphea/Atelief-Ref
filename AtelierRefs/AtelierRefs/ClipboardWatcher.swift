//
//  ClipboardWatcher.swift
//  AtelierRefs
//
//  013 · K3 — the GLUE half of the opt-in clipboard watcher: a 1-second timer, a
//  menu-bar indicator, and one persisted flag. Every actual decision lives in
//  `ClipboardWatch.swift` and is unit-tested there; this file is deliberately
//  thin and is verified by the manual runbook, per the repo's convention for
//  AppKit/menu-bar surfaces.
//
//  Two invariants this file exists to enforce:
//
//  • **Never silent.** The `NSStatusItem` is created when watching starts and
//    torn down when it stops, so its presence IS the running state rather than a
//    label that could drift from it. If the status item cannot be given a button
//    to draw into, `start()` refuses to run at all — "if the user cannot see that
//    it is running, it must not be running" is enforced, not just intended.
//  • **Off by default, and off after a fresh install of a new build.** The flag
//    is read from `UserDefaults` with `object(forKey:) == nil` treated as OFF,
//    never inferred from `bool(forKey:)`'s zero value.
//
//  The flag is namespaced `library.<id>.` per 016 §C — multi-library is deferred,
//  but new keys adopt the prefix from now on so no migration is needed later. A
//  consequence worth stating: the watcher is UNAVAILABLE until the library is
//  open and its id resolves, because a per-library preference cannot be read
//  before we know which library we are in. That is also a sensible privacy
//  posture — nothing ambient can start before the app knows where it would file
//  what it took.
//

import AppKit
import Combine
import Foundation
import os

/// One ambient capture: the image bytes and the best-effort app they came from.
struct ClipboardCapture {
    var imageData: Data
    var app: FrontmostApp
}

@MainActor
final class ClipboardWatcher: ObservableObject {

    /// Whether ambient capture is ON. Persisted per library; **off by default**.
    @Published private(set) var isEnabled = false

    /// Paused from the menu-bar item: enabled, indicator still visible, polling
    /// stopped. Deliberately NOT persisted — a pause is a "not right now", and a
    /// relaunch that came back silently paused would leave a user believing
    /// capture is off when the toggle says on. The indicator changes to a slashed
    /// icon so the two states are distinguishable at a glance.
    @Published private(set) var isPaused = false

    /// The library this watcher's preference belongs to; `nil` until the library
    /// opens. Also the availability gate — see the file header. `@Published` so
    /// the Settings row un-disables itself the moment the library finishes
    /// opening, without the settings window needing to be reopened.
    @Published private(set) var libraryID: String?

    /// Whether the Settings toggle can be operated at all.
    var isAvailable: Bool { libraryID != nil }

    /// Whether the timer is actually polling right now.
    var isWatching: Bool { timer != nil }

    /// Where a capture goes. Set by ``IngestionModel``; a watcher with no sink
    /// polls nothing, since `start()` refuses without one.
    var onCapture: ((ClipboardCapture) -> Void)?

    /// Opens the Settings window from the menu-bar item.
    var onOpenSettings: (() -> Void)?

    /// The poll interval. macOS has no pasteboard notification API; ~1s is the
    /// figure 013 §B settled on — fast enough that a copy feels captured, slow
    /// enough to be free.
    static let pollInterval: TimeInterval = 1

    /// The per-library defaults key. `library.<id>.` per 016 §C item 3, which
    /// names this exact toggle as the reason the discipline exists.
    static func enabledKey(libraryID: String) -> String {
        "library.\(libraryID).clipboardCaptureEnabled"
    }

    private let defaults: UserDefaults
    private let board: () -> any ClipboardBoard
    private let frontmostApp: () -> FrontmostApp
    private var watch = ClipboardWatch(lastChangeCount: 0)
    private var timer: Timer?
    private var statusItem: NSStatusItem?

    init(
        defaults: UserDefaults = .standard,
        board: @escaping () -> any ClipboardBoard = { SystemClipboardBoard() },
        frontmostApp: @escaping () -> FrontmostApp = { FrontmostApp.current() }
    ) {
        self.defaults = defaults
        self.board = board
        self.frontmostApp = frontmostApp
    }

    // MARK: - Lifecycle

    /// Bind to an open library and resume the stored preference.
    ///
    /// Called once from `IngestionModel.bootstrap()`. Until it runs the watcher
    /// reports `isAvailable == false` and cannot be turned on, which is what a
    /// library whose id could not be resolved should look like: no ambient
    /// capture, and a Settings row that says why rather than one that lies.
    func activate(libraryID: String) {
        guard self.libraryID == nil else { return }
        self.libraryID = libraryID
        // Absent key ⇒ OFF. `bool(forKey:)` cannot tell absent from stored-false,
        // and for this feature the two must never be conflated.
        let stored = defaults.object(forKey: Self.enabledKey(libraryID: libraryID)) != nil
            && defaults.bool(forKey: Self.enabledKey(libraryID: libraryID))
        isEnabled = stored
        if stored { start() }
    }

    /// Turn ambient capture on or off — the Settings toggle and the menu item.
    func setEnabled(_ enabled: Bool) {
        guard let libraryID, enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey(libraryID: libraryID))
        isPaused = false
        if enabled { start() } else { stop() }
    }

    /// Pause / resume from the menu-bar item, without forgetting the preference.
    func setPaused(_ paused: Bool) {
        guard isEnabled, paused != isPaused else { return }
        isPaused = paused
        if paused {
            stopTimer()
        } else {
            startTimer()
        }
        refreshIndicator()
    }

    /// Begin watching: show the indicator FIRST, then arm the timer.
    ///
    /// The order is the point. If the status item cannot present a button there
    /// is nowhere for the user to see this running, so nothing starts and the
    /// preference is rolled back rather than left on with an invisible watcher.
    private func start() {
        guard onCapture != nil else {
            // Nothing to hand a capture to. Not reachable through the model, which
            // wires the sink before it activates — but a watcher that polls into
            // the void while telling the user it is capturing is the exact failure
            // this feature must not have.
            AppLog.capture.error("clipboard watcher has no capture sink; not polling")
            forceOff()
            return
        }
        guard showIndicator() else {
            AppLog.capture.error("no menu-bar indicator available; clipboard watcher not started")
            forceOff()
            return
        }
        // Arm from the CURRENT board, so whatever was copied before the user said
        // yes is not swept up (see `ClipboardWatch.init(startingFrom:)`).
        watch = ClipboardWatch(startingFrom: board())
        startTimer()
    }

    /// Turn the preference off because watching could not start safely. Persisted,
    /// not just held in memory: the next launch must not retry into the same
    /// invisible state.
    private func forceOff() {
        isEnabled = false
        isPaused = false
        if let libraryID {
            defaults.set(false, forKey: Self.enabledKey(libraryID: libraryID))
        }
    }

    private func stop() {
        stopTimer()
        hideIndicator()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, which is this class's
            // isolation, but a `Timer` block is not typed that way.
            MainActor.assumeIsolated { self?.tick() }
        }
        // A poll that stalls while a menu is open or a scroll is in flight would
        // silently drop copies, so `.common` rather than the default mode. The
        // tolerance lets the OS coalesce the wake-ups — a 1 s poll should not be a
        // battery line item.
        timer.tolerance = Self.pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - The poll

    /// One observation. Everything interesting is in ``ClipboardWatch/evaluate``;
    /// this only routes the outcome.
    private func tick() {
        switch watch.evaluate(board()) {
        case let .capture(data):
            onCapture?(ClipboardCapture(imageData: data, app: frontmostApp()))
        case let .skip(reason):
            // The reason is a bare case and carries nothing off the pasteboard —
            // that is why logging it at all is safe (see `ClipboardWatch`'s
            // header). `unchanged` is the once-a-second case and is not logged.
            if reason != .unchanged {
                AppLog.capture.debug("clipboard watcher skipped a copy: \(reason.rawValue)")
            }
        }
    }

    // MARK: - Menu-bar indicator

    /// Create the status item. Returns whether the user can actually see it.
    @discardableResult
    private func showIndicator() -> Bool {
        if statusItem != nil { return true }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard item.button != nil else {
            NSStatusBar.system.removeStatusItem(item)
            return false
        }
        statusItem = item
        refreshIndicator()
        return true
    }

    private func hideIndicator() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// Redraw the icon + rebuild the menu for the current state.
    private func refreshIndicator() {
        guard let button = statusItem?.button else { return }
        let symbol = isPaused ? "clipboard" : "clipboard.fill"
        let description = isPaused
            ? "Clipboard capture is paused"
            : "Clipboard capture is on — copied images are saved to Unsorted"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.toolTip = description
        statusItem?.menu = makeMenu()
    }

    /// The click menu: what it is doing, then the two ways to make it stop.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(
            title: isPaused ? "Clipboard Capture — Paused" : "Clipboard Capture — On",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: isPaused ? "Resume" : "Pause",
            action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let off = NSMenuItem(
            title: "Turn Off Clipboard Capture", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)

        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Clipboard Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func togglePause() { setPaused(!isPaused) }

    @objc private func turnOff() { setEnabled(false) }

    @objc private func openSettings() { onOpenSettings?() }
}
