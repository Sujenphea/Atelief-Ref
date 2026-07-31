//
//  UndoStack.swift
//  AtelierRefs
//
//  The undo mechanism both models run on. `SpaceModel` (049) and `IngestionModel`
//  (033/034) each grew their own copy of it — byte-identical down to the recursive
//  ping-pong — and a fix to one silently left the other behind. It lives here once.
//
//  Three decisions are baked in, and all three are load-bearing:
//
//   • **`groupsByEvent = false`.** Each action opens and closes its OWN group, so
//     `canUndo` is correct the instant the action is registered and undo is
//     deterministic in tests, which have no running event loop to close a group for
//     them. Burst coalescing (a frame's per-tile group-drag) is therefore the
//     caller's job — it accumulates the burst and registers ONE reversible.
//
//   • **The serial write chain.** Every persisting op is appended to a FIFO of
//     `Task`s, so an undo can't reorder ahead of the in-flight write it reverses.
//
//   • **The ping-pong.** An undo re-installs its own mirror, so the same pair of
//     closures serves undo → redo → undo indefinitely. During undo/redo
//     `UndoManager` supplies the enclosing group, so `installUndo` must NOT open
//     one — that is the subtlety worth having in a single place.
//
//  The stack deliberately does NOT publish. Its owner keeps the `@Published`
//  `undoToken` (SwiftUI observes the MODEL, and a nested `ObservableObject` would
//  not propagate); `onChange` is how the stack tells it to bump.
//

import Foundation

@MainActor
final class UndoStack {
    /// Private: nothing outside needs the manager itself, and keeping it private is
    /// what stops a caller from registering out-of-band and bypassing the token.
    private let manager = UndoManager()

    /// Runs after every register / undo / redo. The owner bumps its published
    /// `undoToken` here, so the token cannot drift from the stack it describes.
    private let onChange: () -> Void

    /// Serial write queue: each op awaits the previous, so DB writes + reloads stay
    /// strictly ordered even as undo/redo interleave with live edits.
    private var writeChain: Task<Void, Never> = Task {}

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        manager.groupsByEvent = false
    }

    // MARK: - Serialized writes

    /// Await the current tail of the write chain — for tests to observe a settled
    /// state after an edit / undo / redo.
    func waitForWrites() async { await writeChain.value }

    /// Append `work` to the serial write chain (FIFO, strictly ordered).
    func enqueue(_ work: @escaping () async -> Void) {
        let previous = writeChain
        writeChain = Task { @MainActor in
            await previous.value
            await work()
        }
    }

    // MARK: - Registration

    /// Register a reversible action the caller has ALREADY performed, as its own
    /// closed undo group: `inverse` runs on undo, `primary` re-runs on redo,
    /// ping-ponging. Neither runs now.
    func registerReversible(_ name: String,
                            primary: @escaping () -> Void,
                            inverse: @escaping () -> Void) {
        manager.beginUndoGrouping()
        manager.setActionName(name)
        installUndo(name, primary: primary, inverse: inverse)
        manager.endUndoGrouping()
        onChange()
    }

    /// The recursive ping-pong: install an undo that runs `inverse` then re-installs
    /// the mirror for redo. During undo/redo `UndoManager` supplies the enclosing
    /// group, so this must NOT open its own.
    private func installUndo(_ name: String,
                             primary: @escaping () -> Void,
                             inverse: @escaping () -> Void) {
        manager.registerUndo(withTarget: self) { stack in
            inverse()
            stack.installUndo(name, primary: inverse, inverse: primary)
            stack.manager.setActionName(name)
        }
    }

    // MARK: - Drive + interrogate

    var canUndo: Bool { manager.canUndo }
    var canRedo: Bool { manager.canRedo }
    var undoActionName: String { manager.undoActionName }
    var redoActionName: String { manager.redoActionName }

    func undo() { manager.undo(); onChange() }
    func redo() { manager.redo(); onChange() }
}
