//
//  SwitcherPanel.swift
//  AtelierRefs
//
//  099 · P5 — **the ⌘K surface**: a SwiftUI list in an `NSPanel` over the shell.
//
//  Why a panel and not a sheet or a popover, which the app already has recipes for:
//
//   • a SHEET is modal to a window and slides from its title bar — it says "answer
//     this before you carry on", which is the opposite of what a switcher is;
//   • a POPOVER needs an anchor view, and ⌘K has none. It is raised by a key from
//     wherever the keyboard happens to be — including the full-window item-detail
//     overlay and a Space board, neither of which has a control to hang one on.
//
//  A panel over the shell is the shape the platform already uses for exactly this
//  (Spotlight, Open Quickly), and it is the only one of the three that can be
//  raised from every surface without one of them owning it.
//
//  **The responder discipline is `DestinationPicker`'s, and it is the load-bearing
//  part of this file.** A panel that takes first responder and does not give it
//  back leaves the shell alive but deaf: the grid's arrows, the canvas's tools and
//  the detail page's ← → all stop, with nothing on screen to say why. So the
//  controller remembers the host window's first responder BEFORE the panel opens
//  and hands it back on every close path — Escape, Return, a click on a row, a
//  click on the window behind. `SpaceView.restoreCanvasFocus` and
//  `DetailKeyCatcher.restoreResponder` are the same rule in two other files.
//

import AppKit
import AtelierCore
import SwiftUI

// MARK: - The view

/// The switcher's content: a query field over the ranked destination list.
struct SwitcherPanel: View {
    @ObservedObject var model: SwitcherModel
    /// The candidates, in the shared ordering.
    ///
    /// A closure and not an array, because the shell rebuilds this view's struct on
    /// every publish it makes and walking the collection tree each time would be a
    /// tree walk per capture landing. It is called exactly once per presentation, in
    /// `onAppear` — which is also the moment a switcher should read the library:
    /// what the panel offers is what was there when it opened.
    let candidates: () -> [SwitcherCandidate]
    /// The MRU, most recent first.
    let recents: () -> [SidebarItem]
    /// Commit a destination. The caller pops the item-detail overlay and navigates.
    let onSelect: (SidebarItem) -> Void
    /// Close without going anywhere.
    let onDismiss: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if model.results.isEmpty {
                emptyRow
            } else {
                Divider().overlay(Theme.Colors.hairline)
                list
            }
        }
        .frame(width: SwitcherLayout.width)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.hairline))
        .onAppear {
            model.open(candidates: candidates(), recents: recents())
            // Hopped off the update that installs the panel: the panel is not key
            // yet inside `onAppear`, and focus taken before then does not stick.
            // The same hop `DestinationPicker` and `SpaceView.restoreCanvasFocus`
            // take, for the same reason.
            Task { @MainActor in fieldFocused = true }
        }
    }

    // MARK: The field

    private var field: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.inkSecondary)

            // Every key this panel reads is attached HERE rather than to the
            // container, because the field is what holds focus and SwiftUI delivers
            // a key press to the focused view first. `LibrarySearch`'s search field
            // reads Escape the same way.
            TextField("Go to…", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .focused($fieldFocused)
                .accessibilityIdentifier(AccessibilityID.switcherField)
                // Return, through `onSubmit` rather than `onKeyPress(.return)`:
                // a Return in a macOS text field is a submit, and routing it any
                // other way is fighting the field editor for no gain.
                .onSubmit(commit)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                // Escape is handled here rather than left to the panel, so the
                // caller's `onDismiss` runs on this path too — that is where the
                // keyboard goes back to the shell (`DestinationPicker`'s note).
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm + 2)
    }

    // MARK: The list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.results) { match in
                        SwitcherRow(
                            candidate: match.candidate,
                            isHighlighted: match.destination == model.highlighted,
                            onHover: { model.highlight(match.destination) },
                            action: { onSelect(match.destination) })
                            .id(match.destination)
                    }
                }
                .padding(Theme.Spacing.xs)
            }
            // A fixed cap rather than shrink-to-fit: the panel is a floating window,
            // and a window that resizes on every keystroke is a window that appears
            // to twitch. The list scrolls past the cap instead, which is
            // `CollectionDestinationList`'s answer to the same question.
            .frame(height: SwitcherLayout.listHeight)
            .scrollBounceBehavior(.basedOnSize)
            // Keep the cursor on screen past the cap — arrowing to a row you cannot
            // see is the same as arrowing to nothing.
            .onChange(of: model.highlighted) { _, destination in
                guard let destination else { return }
                proxy.scrollTo(destination, anchor: .center)
            }
        }
    }

    private var emptyRow: some View {
        Text("No destination matches “\(model.query)”")
            .font(Theme.Typography.row)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: Keys

    /// Walk the cursor. `.handled` even at a stop, so an ↑ on the first row is
    /// absorbed here rather than reaching the field editor, which would jump the
    /// caret to the start of the query.
    private func move(_ delta: Int) -> KeyPress.Result {
        model.move(delta)
        return .handled
    }

    private func commit() {
        guard let target = model.commitTarget else { return }
        onSelect(target)
    }
}

/// One destination row: glyph, title, and where it lives.
///
/// **Internal rather than `private` since 099 · P6**, which is the whole of the
/// seam the reference palette's picker needed: two surfaces search one list of
/// destinations, so they must not disagree about what a destination LOOKS like
/// either. The palette hosts this row in its own popover with its own geometry and
/// its own accessibility prefix; everything else about it is this file's.
struct SwitcherRow: View {
    let candidate: SwitcherCandidate
    let isHighlighted: Bool
    let onHover: () -> Void
    let action: () -> Void
    /// The row's accessibility identifier. Defaulted to the ⌘K panel's spelling; the
    /// palette passes its own so a UI flow can say WHICH surface it found the row on
    /// — both can be on screen at once.
    var identifier: String?

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: candidate.symbol)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 16)
                Text(candidate.title)
                    .font(Theme.Typography.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.sm)
                if !candidate.detail.isEmpty {
                    Text(candidate.detail)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .foregroundStyle(Theme.Colors.inkPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(isHighlighted ? Theme.Colors.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? AccessibilityID.switcherRow(candidate.title))
        // Hover MOVES the cursor rather than drawing a second highlight, so the row
        // Return would take can never be ambiguous — the opposite trade to
        // `SelectionMenuRow`, which has a pointer-driven caller to stay quiet for.
        .onHover { if $0 { onHover() } }
    }
}

/// The panel's geometry. A `*Layout` enum rather than literals at the call site,
/// per ``Theme``'s header.
nonisolated enum SwitcherLayout {
    /// Wide enough for a collection name plus its ancestor path without either
    /// truncating in an ordinary library.
    static let width: CGFloat = 560
    /// The list's fixed height — about nine rows. See ``SwitcherPanel/list``.
    static let listHeight: CGFloat = 300
    /// How far below the host window's top edge the panel's top edge sits. The
    /// shell's toolbar band is ~52pt; this clears it and still reads as attached to
    /// the window rather than floating in the middle of the screen.
    static let topInset: CGFloat = 96
    /// The narrowest the panel will go, when the host window is smaller than
    /// ``width`` plus its margins.
    static let minimumWidth: CGFloat = 320
    /// Left free on each side of the panel when the host window is narrow.
    static let sideMargin: CGFloat = 40
}

// MARK: - The window

/// A borderless panel that can take the keyboard.
///
/// `canBecomeKey` is the override that makes this work at all: a borderless window
/// refuses key status by default, so without it the field below would never see a
/// keystroke. `NSPanel` rather than `NSWindow` for `hidesOnDeactivate` — a switcher
/// must not float over another app the user has switched to.
final class SwitcherPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Deliberately NOT main. The shell stays the main window, so its menu state,
    /// its focused-scene values and its title bar are unchanged while the panel is
    /// up — which is what lets ⌘K be raised from a Space board and still commit
    /// into the window that raised it.
    override var canBecomeMain: Bool { false }
}

/// Owns the ⌘K panel's window: where it sits, when it opens, and — the part that
/// matters — who has the keyboard after it closes.
@MainActor
final class SwitcherPanelController {

    private(set) var panel: SwitcherPanelWindow?
    /// The host window's first responder at the moment the panel opened. Handed
    /// back on every close path; see the file header.
    private weak var restoreResponder: NSResponder?
    // `nonisolated(unsafe)` for one reason and one only: `deinit` is nonisolated on
    // a `@MainActor` class, and an observer token that a deinit cannot read is an
    // observer that outlives the object holding it. Nothing else touches these off
    // the main actor — every write below is in a main-actor method — and by the
    // time `deinit` runs nothing else can reach them at all.
    nonisolated(unsafe) private var resignObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var hostResizeObserver: (any NSObjectProtocol)?

    /// Called when the panel loses the keyboard to another window of this app — a
    /// click on the shell behind it. The host clears its own presentation state
    /// through this rather than the controller closing itself, so SwiftUI's binding
    /// and the window can never disagree about whether the panel is up.
    var onDismissRequest: (() -> Void)?

    var isPresented: Bool { panel != nil }

    init() {}

    // MARK: Geometry

    /// Where a panel of `size` sits over a host window at `hostFrame`: horizontally
    /// centred, its TOP edge ``SwitcherLayout/topInset`` below the host's.
    ///
    /// Pure, and in screen coordinates (AppKit's y grows upward), so the one piece
    /// of arithmetic here is a test rather than a screenshot.
    nonisolated static func origin(forPanelSize size: NSSize, over hostFrame: NSRect) -> NSPoint {
        NSPoint(
            x: (hostFrame.midX - size.width / 2).rounded(),
            y: (hostFrame.maxY - SwitcherLayout.topInset - size.height).rounded())
    }

    /// How wide the panel is over a host of `hostWidth` — ``SwitcherLayout/width``,
    /// narrowed to leave a margin on a window too small for it, and never below
    /// ``SwitcherLayout/minimumWidth``.
    nonisolated static func width(forHostWidth hostWidth: CGFloat) -> CGFloat {
        max(
            SwitcherLayout.minimumWidth,
            min(SwitcherLayout.width, hostWidth - 2 * SwitcherLayout.sideMargin))
    }

    // MARK: Presenting

    /// Show the panel over `host`.
    ///
    /// A no-op while one is already up, deliberately: the shell re-renders on every
    /// publish it makes, and re-installing a root view each time would re-render the
    /// panel for reasons that have nothing to do with it. The panel's content is
    /// driven by its own ``SwitcherModel``, which publishes for itself.
    func present(over host: NSWindow, rootView: AnyView) {
        guard !isPresented else { return }
        // Taken BEFORE anything is ordered in — once the panel is key, the host's
        // own first responder is still whatever it was, but the order is the part
        // a later reader has to be able to trust.
        restoreResponder = host.firstResponder

        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = [.preferredContentSize]
        let panel = SwitcherPanelWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: SwitcherLayout.width, height: 1)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityLabel("Go to")

        self.panel = panel

        host.addChildWindow(panel, ordered: .above)
        reposition()
        panel.makeKeyAndOrderFront(nil)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Hopped a turn so app deactivation has already been recorded: losing
            // key because the USER SWITCHED APPS must not close the panel (it hides
            // with the app and comes back), while losing it to the shell behind
            // must.
            Task { @MainActor in
                guard let self, self.isPresented, NSApp.isActive else { return }
                self.onDismissRequest?()
            }
        }
        // Two resizes to follow, and the SECOND is the one that is easy to miss.
        // The host's, so the panel stays centred while the window is dragged out —
        // and the PANEL'S OWN, because `sizingOptions = [.preferredContentSize]`
        // lets SwiftUI change its height (an empty result list is shorter than a
        // full one) and an `NSWindow` resize keeps its BOTTOM-left origin. Without
        // the second observer the panel grows UPWARD off its anchor the first time
        // a query stops matching.
        hostResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                guard window === panel || window === panel.parent else { return }
                self.reposition()
            }
        }
    }

    /// Re-anchor the panel over its host.
    ///
    /// Guarded on an actual change, because this is called FROM a resize
    /// notification and an unconditional `setFrame` would post another.
    func reposition() {
        guard let panel, let host = panel.parent else { return }
        var frame = panel.frame
        frame.size.width = Self.width(forHostWidth: host.frame.width)
        frame.origin = Self.origin(forPanelSize: frame.size, over: host.frame)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: false)
    }

    /// Close, and hand the keyboard back.
    ///
    /// Idempotent: every close path in the panel (Escape, Return, a row click, the
    /// binding going false, the view being dismantled) reaches here, and two of
    /// them routinely arrive in the same runloop turn.
    func dismiss() {
        guard let panel else { return }
        let host = panel.parent
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let hostResizeObserver { NotificationCenter.default.removeObserver(hostResizeObserver) }
        resignObserver = nil
        hostResizeObserver = nil
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentViewController = nil
        self.panel = nil

        guard let host else { restoreResponder = nil; return }
        // Key first, then the responder: making a window key does not reset its
        // first responder, but the reverse order would set a responder on a window
        // that is about to be re-keyed. Guarded on `NSApp.isActive` so a dismiss
        // that happens because the user left for another app does not yank focus
        // back to us.
        if NSApp.isActive { host.makeKey() }
        if let restoreResponder { host.makeFirstResponder(restoreResponder) }
        restoreResponder = nil
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let hostResizeObserver { NotificationCenter.default.removeObserver(hostResizeObserver) }
    }
}

// MARK: - The SwiftUI seam

/// The anchor view's only job is to be IN the window, so the controller can find
/// one. It draws nothing, and it refuses every mouse event: this sits in the
/// shell's `.background`, which spans the whole window, and a plain `NSView` there
/// would hit-test ahead of nothing but would still be a live target for any point
/// SwiftUI's own content declines. Returning `nil` from `hitTest` takes it out of
/// the mouse's world entirely, which is what a zero-cost anchor has to be.
private final class SwitcherPanelAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A zero-size view that puts ``SwitcherPanel`` in a panel over whatever window it
/// finds itself in, while `isPresented` is true.
///
/// Placed in the shell's `.background`, so the panel is raised from the SHELL
/// rather than from a pane: ⌘K has to work inside the item-detail overlay and on a
/// Space board, and a host attached to a pane would unmount with it.
struct SwitcherPanelHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSView {
        let view = SwitcherPanelAnchorView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onDismissRequest = { isPresented = false }
        context.coordinator.sync(
            isPresented: isPresented, host: view, rootView: AnyView(content()))
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.controller.dismiss()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let controller = SwitcherPanelController()

        var onDismissRequest: (() -> Void)? {
            didSet { controller.onDismissRequest = onDismissRequest }
        }

        func sync(isPresented: Bool, host: NSView, rootView: AnyView) {
            guard isPresented else { controller.dismiss(); return }
            if let window = host.window {
                controller.present(over: window, rootView: rootView)
            } else {
                // The shell's background view can be updated before it is in a
                // window (the first layout pass after a scene opens). One hop is
                // enough — `updateNSView` runs again on the next state change
                // anyway, and a retry loop here would outlive the view.
                Task { @MainActor [weak host] in
                    guard let host, let window = host.window, isPresented else { return }
                    self.controller.present(over: window, rootView: rootView)
                }
            }
        }
    }
}
