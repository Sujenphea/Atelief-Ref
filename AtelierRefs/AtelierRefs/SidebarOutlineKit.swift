//
//  SidebarOutlineKit.swift
//  AtelierRefs
//
//  043 · Phase C — the shared AppKit skeleton for the sidebar's `NSOutlineView`
//  trees. Both the Collections tree (``CollectionsOutlineView``) and the flat
//  Spaces list (``SpacesOutlineView``) drive their own coordinators but render
//  through THESE primitives, so a row / cell / draft-field / selection styling
//  change lands in one place for both:
//
//   • ``SidebarOutlineView`` — the outline view with the native LEFT disclosure
//     triangle suppressed and single-column auto-fill (no enclosing scroll view).
//   • ``SidebarRowView`` — flat, borderless Theme-tinted selection (no focus ring).
//   • ``SidebarCell`` — name label + optional right-aligned chevron BUTTON (parents
//     only, 025 · S1).
//   • ``SidebarDraftCell`` — the inline editable field, used for BOTH the "new item"
//     draft (214) and rename-in-place (025 · S2).
//   • ``SidebarEditState`` — the pure state machine behind that field: what a
//     session is editing and what finishing it should do.
//   • ``BlockMenuItem`` — a closure-backed `NSMenuItem` for dynamic row menus.
//
//  The coordinators own everything that DIFFERS (nesting vs flat, drag routing,
//  data source); this file owns everything that's the SAME.
//

import AppKit

/// The one piece of geometry the sidebar's SwiftUI shell and its AppKit outline views
/// have to AGREE on. Both draw into ``SidebarView``'s column but are laid out by
/// different frameworks, so a measurement taken across that seam is named here rather
/// than written out on each side of it.
enum SidebarMetrics {
    /// How far both outline views extend INTO the sidebar's trailing padding, so a
    /// row's fill and selection reach closer to the edge than the section headers and
    /// nav rows do.
    ///
    /// Named because ``SidebarCell`` measures its chevron against it: the cell's
    /// trailing edge sits this much further right than a header's, and the row chevron
    /// still has to line up with that header's "+". Changing the overhang without this
    /// constant is exactly how the two drifted 6pt apart.
    static let outlineOverhang: CGFloat = 8
}

/// The outline view with the native LEFT disclosure triangle suppressed — the cell
/// draws its own chevron on the right (043 · Phase C styling).
final class SidebarOutlineView: NSOutlineView {
    /// A key-event hook for the owning coordinator (025 · S3 — Enter renames the
    /// selected row). Return `true` to consume the event; `false` falls through to
    /// `super`, which is what keeps →/← expand/collapse and ↑/↓ selection native.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// NSOutlineView reserves a fixed leading gap for the (now-hidden) disclosure
    /// triangle. Strip that constant gap so the cell's own 14pt inset is the only
    /// leading padding, keeping ONLY the per-level indentation on top.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let indent = CGFloat(level(forRow: row)) * indentationPerLevel
        let gap = frame.origin.x - indent
        frame.origin.x -= gap
        frame.size.width += gap
        return frame
    }

    /// Without an enclosing scroll view the single column doesn't auto-fill; track
    /// the view width so rows (and their selection / click target) span the sidebar.
    override func layout() {
        super.layout()
        if let column = tableColumns.first, column.width != bounds.width {
            column.width = bounds.width
        }
    }
}

/// A row whose selection is a flat, borderless Theme fill (no focus ring, no
/// emphasized blue) — matches the SwiftUI sidebar's active-row look.
final class SidebarRowView: NSTableRowView {
    /// Draw the selection fill even when the row isn't selected — the inline draft
    /// row (214) uses this so it matches the active/selected row while typing.
    /// `drawSelection` isn't invoked for unselected rows, so the forced case draws
    /// from `drawBackground` instead.
    var forceSelected = false {
        didSet { if forceSelected != oldValue { needsDisplay = true } }
    }

    /// Pointer-over feedback for an unselected row — the AppKit analogue of the SwiftUI
    /// nav rows' `.hoverHighlight`, so hovering a space / collection reads the same as
    /// hovering Home / Capture / Settings. Suppressed under selection / force-select.
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverTracking: NSTrackingArea?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if forceSelected {
            drawHighlight()
        } else if isHovered && !isSelected {
            drawHoverHighlight()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // `!forceSelected` so a row that is BOTH selected and force-selected (a
        // rename session on the row you are already on, 025 · S2) paints the fill
        // once rather than stroking its border twice.
        guard isSelected, !forceSelected else { return }
        drawHighlight()
    }

    /// Left-flush (roots have 0 x offset, so the fill must start at 0 too, else the
    /// name overhangs it); small right + vertical inset for the rounded look.
    private var highlightRect: NSRect {
        NSRect(x: 0, y: 2, width: bounds.width - 4, height: bounds.height - 4)
    }

    private func drawHighlight() {
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6)
        Theme.NS.selection.setFill()
        path.fill()
        Theme.NS.hairlineStrong.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The subtle hover fill — the same `hoverRow` token the SwiftUI nav rows use, so
    /// hovering a space reads identically to hovering Home. Fill only (no border), so it
    /// stays a lighter step below the bordered `selection` state.
    private func drawHoverHighlight() {
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6)
        Theme.NS.hoverRow.setFill()
        path.fill()
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        // Reconcile after reuse / scroll / relayout: `mouseEntered` won't fire if the
        // pointer was already over the row before this tracking area existed, and a
        // recycled row could otherwise keep a stale hover from its previous item.
        if let window = window {
            let inView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = bounds.contains(inView)
        } else {
            isHovered = false
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A sidebar row cell: name text in the Theme row font, NO leading icon, and a
/// right-aligned chevron BUTTON that expands/collapses (shown only for parents — a
/// flat list like Spaces simply configures `expandable: false`).
///
/// 025 · S1 — the chevron used to be a decorative `NSImageView` while the ROW
/// handled the toggle, so one click both navigated and toggled: you could not
/// expand a folder without leaving the page you were on, and the click that opened
/// a parent collapsed the children you had just opened. The glyph stays trailing
/// (the visual identity is deliberate); only the interaction split.
final class SidebarCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = SidebarChevronButton()

    /// The accessibility-identifier prefix this outline's rows carry (099 · P2), or
    /// `nil` for an outline no test drives.
    ///
    /// A per-CELL value rather than a shared constant because both sidebar trees are
    /// this class — the collections tree and the flat Spaces list — and a UI test that
    /// asks for "the rows" has to be able to say which tree it means. `NSOutlineView`
    /// reuses cells only within one outline, so a value fixed at init is safe.
    ///
    /// The identifiers land on ``label`` and ``chevron``, never on the cell: an
    /// identifier on the container would name the row and leave the control inside it
    /// unaddressable, which is the failure 098 hit on the phone.
    private let accessibilityPrefix: String?

    /// Fired by the chevron button only. The row's own click never toggles.
    var onToggle: (() -> Void)?

    /// The glyph stays 12pt — the BUTTON is padded to ``chevronButton`` around it for a
    /// comfortable hit area, the same trade the detail pager's chevrons make.
    private static let glyph = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    private static let chevronButton: CGFloat = 20

    /// Where a section header's "+" centres, measured in from the SIDEBAR's trailing
    /// edge: the `Spacing.lg` content inset, ``HoverHighlight``'s 6pt pad, and half of
    /// the 12pt `plus` glyph inside it.
    private static let headerGlyphCenter: CGFloat = Theme.Spacing.lg + 6 + 6

    /// The chevron button's inset from the CELL's trailing edge, chosen so its glyph
    /// shares a centre x with that "+". The cell overhangs the header's content edge by
    /// ``SidebarMetrics/outlineOverhang``, so the same centre is that much nearer here;
    /// half the button width then puts its EDGE at the value below.
    ///
    /// Centres, not edges: `chevron.right` is 9pt wide and `chevron.down` 14pt, so an
    /// edge-aligned glyph would shift sideways every time the row toggles. (The former
    /// -4 came from 074 · S1, where it preserved the pre-button glyph's 8pt inset — a
    /// measurement inherited from the decorative `NSImageView` and never checked
    /// against the header it sits under, which left the two 6pt out.)
    private static let chevronInset =
        headerGlyphCenter - SidebarMetrics.outlineOverhang - chevronButton / 2

    init(identifier: NSUserInterfaceItemIdentifier, accessibilityPrefix: String? = nil) {
        self.accessibilityPrefix = accessibilityPrefix
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 13)              // Theme.Typography.row, snug
        label.textColor = Theme.NS.inkPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.isBordered = false
        chevron.title = ""
        chevron.imagePosition = .imageOnly
        // `.momentaryChange` swaps nothing on press: a bordered-less image button
        // otherwise paints AppKit's grey pressed plate behind the glyph.
        chevron.setButtonType(.momentaryChange)
        chevron.contentTintColor = Theme.NS.inkSecondary
        chevron.imageScaling = .scaleProportionallyDown
        chevron.focusRingType = .none
        chevron.target = self
        chevron.action = #selector(chevronPressed)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(chevron)
        textField = label
        NSLayoutConstraint.activate([
            // Roots sit at 14pt; children add the outline view's per-level indent.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // -2 to the button's EDGE; the glyph sits a further ~3-5pt inside its pad,
            // so what the eye reads is a comfortable gap, not a 2pt one.
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -2),
            chevron.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.chevronInset),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Self.chevronButton),
            chevron.heightAnchor.constraint(equalToConstant: Self.chevronButton),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, expandable: Bool, expanded: Bool) {
        label.stringValue = name
        // Re-stamped on every configure, not set once at init: cells are recycled, so a
        // row that keeps a previous occupant's identifier is worse than having none.
        if let accessibilityPrefix {
            label.setAccessibilityIdentifier(accessibilityPrefix + name)
            chevron.setAccessibilityIdentifier(accessibilityPrefix + name + ".disclosure")
        }
        chevron.isHidden = !expandable
        chevron.isEnabled = expandable
        setExpanded(expanded)
    }

    /// Flip the chevron glyph to match the expansion state. Driven by the outline's
    /// `outlineViewItemDidExpand` / `…DidCollapse` delegates, so EVERY expansion
    /// path refreshes it — the click, the keyboard, and programmatic reveals like
    /// `expandAncestors` (which used to leave a stale glyph behind).
    func setExpanded(_ expanded: Bool) {
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Collapse" : "Expand"
        )?.withSymbolConfiguration(Self.glyph)
    }

    @objc private func chevronPressed() { onToggle?() }
}

/// The disclosure chevron's button, which answers the pointer the way every other
/// chrome glyph button does.
///
/// 074 · S1 gave the chevron a 20pt hit area of its own but no hover state, so the
/// one genuinely clickable target inside a row looked as inert as the label beside
/// it — the row's `hoverRow` fill underneath reads as "this ROW is hoverable", which
/// is the opposite of what the split was for. `NSButton` draws no hover of its own,
/// so this is the AppKit half of ``HoverButtonStyle``: the same
/// ``Theme/Colors/hoverControl`` token at the same ``Theme/Radius/control``, a step
/// up from the row fill it sits on.
final class SidebarChevronButton: NSButton {
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverTracking: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            let path = NSBezierPath(
                roundedRect: bounds,
                xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
            Theme.NS.hoverControl.setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        // The same reconcile ``SidebarRowView`` needs, for the same reasons: cells are
        // recycled, so a reused button can carry a stale hover from the row it used to
        // be, and `mouseEntered` never fires for a pointer that was already inside
        // before this tracking area existed.
        if let window = window {
            let inView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = bounds.contains(inView)
        } else {
            isHovered = false
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The inline editable cell: a borderless text field pixel-matched to
/// ``SidebarCell``'s label. Enter / focus-loss commit, Escape cancels; a one-shot
/// `finished` guard stops Enter's end-editing echo from committing twice.
///
/// Used for BOTH the "new item" draft row (214) and rename-in-place (025 · S2) —
/// the suspend/restore, the commit-once guard and the shared-field-editor
/// transparency fix are identical for the two, which is the whole reason rename
/// reuses this cell instead of growing a second editable one.
final class SidebarDraftCell: NSTableCellView, NSTextFieldDelegate {
    // Built from `labelWithString:` (the plain, non-bezeled variant SidebarCell uses)
    // then made editable — NOT `NSTextField(string:)`, whose bezel paints the dark
    // control fill that no amount of `isBezeled`/`drawsBackground` toggling on an
    // already-bezeled field reliably clears.
    let field = NSTextField(labelWithString: "")
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    /// Set true around a programmatic teardown reload so the resulting end-editing
    /// callback isn't misread as a user commit/cancel.
    var isSuspended = false
    private var finished = false

    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { field.placeholderString = newValue }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.font = .systemFont(ofSize: 13)              // matches SidebarCell label
        field.textColor = Theme.NS.inkPrimary
        // A label is non-editable by default — flip it on. It stays visually plain
        // (no bezel, no border, transparent), so the row highlight shows through and
        // `drawsBackground = false` keeps the field editor transparent while editing.
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true       // long names scroll while typing, not clip
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            // Same 14pt leading inset as SidebarCell (per-level indent is added by
            // the outline view on top), a small trailing gap, vertically centered.
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-arm a (possibly reused) cell for a fresh edit — clears the guards.
    func prepareForEditing() {
        finished = false
        isSuspended = false
    }

    func controlTextDidChange(_ obj: Notification) { onTextChange?(field.stringValue) }

    /// Focus loss (click elsewhere, row torn down): Finder-style commit-or-cancel.
    func controlTextDidEndEditing(_ obj: Notification) { finish(cancelled: false) }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(cancelled: false); return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Catches Escape even with the field editor's completion popup up.
            finish(cancelled: true); return true
        default:
            return false
        }
    }

    private func finish(cancelled: Bool) {
        guard !finished, !isSuspended else { return }
        finished = true
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if cancelled || name.isEmpty { onCancel?() } else { onCommit?(name) }
    }
}

// MARK: - Inline edit session (025 · S2)

/// What an inline sidebar edit is editing. The draft session (214) was always
/// *"a new item under parent P"*; generalising it to *"an editing session on row R"*
/// is all rename-in-place needs — a rename swaps an EXISTING row's cell, so none of
/// the phantom-row / drop-index / reload machinery changes.
enum SidebarEditSession: Equatable {
    /// A phantom row appended under `parent` (`nil` ⇒ the root list).
    case draft(parent: UUID?)
    /// The existing row for `id`, edited in place.
    case rename(id: UUID)
}

/// The live state of an inline edit — the pure half of both outline coordinators'
/// session handling, so the rules below are unit-testable without an `NSOutlineView`.
struct SidebarEditState: Equatable {
    let session: SidebarEditSession
    /// The name the row carried when the session opened (empty for a draft). For a
    /// rename this is what "unchanged" is measured against, so committing without
    /// typing writes nothing — and therefore registers no spurious undo entry.
    let originalName: String
    /// Mirrors the field live, so a model reload landing mid-edit can restore it.
    var text: String
    /// Set on commit: the row stays a static label carrying this name until the
    /// model's refresh lands, so the swap in is jump-free.
    var committedName: String?

    init(session: SidebarEditSession, originalName: String = "") {
        self.session = session
        self.originalName = originalName
        self.text = originalName
    }

    /// The row this session is editing, when it is a rename.
    var renameID: UUID? {
        if case let .rename(id) = session { return id }
        return nil
    }

    /// Does this session edit the row for `id`?
    func isRenaming(_ id: UUID) -> Bool { renameID == id }
}

/// What finishing a session should actually DO.
enum SidebarEditOutcome: Equatable {
    case create(parent: UUID?, name: String)
    case rename(id: UUID, name: String)
    /// Nothing is written and the row reverts: an explicit Escape, an empty or
    /// whitespace-only name, or a rename that ended on the name it started with.
    case cancel
}

extension SidebarEditState {
    /// Resolve a finished session. `name == nil` is a cancel (Escape); anything else
    /// is the field's text, which is trimmed here so the rules hold whatever the
    /// caller passes.
    func outcome(committing name: String?) -> SidebarEditOutcome {
        guard let name else { return .cancel }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .cancel }
        switch session {
        case let .draft(parent):
            return .create(parent: parent, name: trimmed)
        case let .rename(id):
            guard trimmed != originalName else { return .cancel }
            return .rename(id: id, name: trimmed)
        }
    }
}

/// A closure-backed `NSMenuItem` (the outline row menus build items dynamically;
/// target/action selectors would need one method per action). Mirrors the private
/// helper `MasonryGridHost` uses for the same reason, but shared by BOTH sidebar
/// coordinators (043 · Phase C), so it is `internal` and distinctly named (a
/// module-level clone of the name would collide with the grid's file-private copy).
/// `nonisolated` because `NSMenuItem`'s designated initializers are: under this
/// target's MainActor-by-default the subclass would infer main-actor isolation and
/// fail to match what it overrides. The handler is typed `@MainActor` instead —
/// AppKit delivers menu actions on the main thread, and every closure passed here
/// touches main-actor state, so the isolation belongs on the CLOSURE rather than
/// on the menu item that merely carries it.
nonisolated final class SidebarBlockMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    nonisolated required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor @objc private func fire() { handler() }
}
