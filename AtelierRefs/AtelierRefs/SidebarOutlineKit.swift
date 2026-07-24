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
//   • ``SidebarCell`` — name label + optional right-aligned chevron (parents only).
//   • ``SidebarDraftCell`` — the inline "new item" editable field (214).
//   • ``BlockMenuItem`` — a closure-backed `NSMenuItem` for dynamic row menus.
//
//  The coordinators own everything that DIFFERS (nesting vs flat, drag routing,
//  data source); this file owns everything that's the SAME.
//

import AppKit

/// The outline view with the native LEFT disclosure triangle suppressed — the cell
/// draws its own chevron on the right (043 · Phase C styling).
final class SidebarOutlineView: NSOutlineView {
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

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if forceSelected { drawHighlight() }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        drawHighlight()
    }

    /// Left-flush (roots have 0 x offset, so the fill must start at 0 too, else the
    /// name overhangs it); small right + vertical inset for the rounded look.
    private func drawHighlight() {
        let rect = NSRect(x: 0, y: 2, width: bounds.width - 4, height: bounds.height - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor(hex: 0x3A3A40).setFill()                        // Theme.Colors.selection
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()      // Theme.Colors.hairlineStrong
        path.lineWidth = 1
        path.stroke()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A sidebar row cell: name text in the Theme row font, NO leading icon, and a
/// right-aligned chevron that expands/collapses (shown only for parents — a flat
/// list like Spaces simply configures `expandable: false`).
final class SidebarCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()   // indicator only — the row handles toggle

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 13)              // Theme.Typography.row, snug
        label.textColor = NSColor(hex: 0xF2F1EE)          // inkPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = NSColor(hex: 0x9A9A9E) // inkSecondary
        chevron.imageScaling = .scaleProportionallyDown
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(chevron)
        textField = label
        NSLayoutConstraint.activate([
            // Roots sit at 14pt; children add the outline view's per-level indent.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, expandable: Bool, expanded: Bool) {
        label.stringValue = name
        chevron.isHidden = !expandable
        setExpanded(expanded)
    }

    /// Flip the chevron glyph to match the expansion state — called immediately on
    /// toggle so it never lags.
    func setExpanded(_ expanded: Bool) {
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
    }
}

/// The inline draft row's editable cell (214): a borderless text field pixel-matched
/// to ``SidebarCell``'s label. Enter / focus-loss commit, Escape cancels; a one-shot
/// `finished` guard stops Enter's end-editing echo from committing twice.
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
        field.textColor = NSColor(hex: 0xF2F1EE)          // inkPrimary
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

/// A closure-backed `NSMenuItem` (the outline row menus build items dynamically;
/// target/action selectors would need one method per action). Mirrors the private
/// helper `MasonryGridHost` uses for the same reason, but shared by BOTH sidebar
/// coordinators (043 · Phase C), so it is `internal` and distinctly named (a
/// module-level clone of the name would collide with the grid's file-private copy).
final class SidebarBlockMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
