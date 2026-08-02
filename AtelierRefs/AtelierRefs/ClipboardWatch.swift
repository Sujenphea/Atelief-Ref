//
//  ClipboardWatch.swift
//  AtelierRefs
//
//  013 · K3 — the DECIDING half of the opt-in clipboard watcher. Everything that
//  answers "should this pasteboard become a library item?" lives here, behind an
//  injected pasteboard seam, so every privacy rule the feature promises is a unit
//  test rather than a claim about a timer.
//
//  The rules, in the order they are applied, and why that order:
//    1. `changeCount` did not move → nothing happened. This gate comes first
//       because it is the one that runs ~once a second forever; everything below
//       it runs only on a real copy.
//    2. `org.nspasteboard.ConcealedType` → skip. Password managers mark their
//       copies with it. Nothing below this line runs, so the bytes are never
//       read, never hashed, never logged.
//    3. `org.nspasteboard.TransientType` → skip. "Do not persist this" is a
//       request this feature is precisely in the business of honouring.
//    4. `AssetDragPayload.pasteboardType` → skip: this is OUR OWN copy coming
//       back at us (see the note on `Skip.ownCopy`).
//    5. No image representation → skip. Images only. Never text, never files —
//       the difference between a reference tool and a keylogger.
//
//  Deliberate omission: there is no case that carries a description, a type list,
//  a byte count, or a snippet. ``Skip`` cases are bare so that a caller who logs
//  a decision — and one does — CANNOT leak what was on the pasteboard. That is a
//  property of the type, not a rule someone has to remember at each call site.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// A pasteboard, reduced to the three questions the watcher asks of it.
///
/// The seam exists for the reason ``FolderAccess``'s does: the real conformer is
/// a five-line wrapper over an OS singleton that a test process cannot safely
/// drive (writing to `NSPasteboard.general` in a test would clobber the
/// developer's actual clipboard), while the logic above it — every skip rule —
/// is worth testing exhaustively.
protocol ClipboardBoard {
    /// The system's monotonically-increasing "the contents changed" counter.
    /// macOS has no pasteboard notification API, which is the whole reason this
    /// feature polls.
    var changeCount: Int { get }

    /// Every type present on the board. Conformers are expected to report the
    /// union across ALL items rather than just the first: a marker seen on any
    /// item must be able to veto the whole board, and over-reporting can only
    /// cause a skip — the safe direction.
    var availableTypes: [NSPasteboard.PasteboardType] { get }

    /// The bytes for `type`, or `nil`. Only ever called AFTER the marker gates
    /// pass, so a concealed board's data is never requested.
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

/// Why an observation produced no capture. Bare cases on purpose — see the file
/// header: a reason must not be able to carry pasteboard content.
enum ClipboardSkip: String, Equatable, CaseIterable {
    /// `changeCount` is where we left it — nobody copied anything.
    case unchanged
    /// Marked `org.nspasteboard.ConcealedType` (a password manager).
    case concealed
    /// Marked `org.nspasteboard.TransientType` ("don't persist me").
    case transient
    /// Carries this app's private `com.ref-atelier.asset-ids` type, so the copy
    /// came FROM the library and re-ingesting it would duplicate an asset the
    /// user already has.
    case ownCopy
    /// No image representation. Text, files, and everything else are out of
    /// scope by design.
    case noImage
}

/// The outcome of one observation.
enum ClipboardDecision: Equatable {
    /// Capture these bytes. The payload is the raw image representation, handed
    /// to the ordinary ingest path unchanged.
    case capture(Data)
    /// Do nothing, for this reason.
    case skip(ClipboardSkip)
}

/// The watcher's decision core: a `changeCount` and the rules applied to a board
/// whose count has moved. No timer, no `NSPasteboard.general`, no ingest.
struct ClipboardWatch {

    /// Password managers and clipboard utilities agree on these two identifiers
    /// by convention (`nspasteboard.org`), not by any Apple API — there is no
    /// typed constant to use, so they are spelled out here once.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The image representations recognized, in preference order — the SAME
    /// three, in the same order, that ``DirectInputReader`` reads off a pasted
    /// board. Ambient capture and ⌘V must agree on what counts as an image;
    /// disagreeing would mean the watcher silently ignoring things the user can
    /// paste, or vice versa.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),  // "public.jpeg"
    ]

    /// The last `changeCount` this watcher has already judged.
    private(set) var lastChangeCount: Int

    /// Start from an explicit count — the form tests use.
    init(lastChangeCount: Int) {
        self.lastChangeCount = lastChangeCount
    }

    /// Start from whatever is on `board` RIGHT NOW, having judged none of it.
    ///
    /// This is how the watcher is armed, and it is a privacy rule rather than an
    /// optimization: turning ambient capture on must not sweep up the thing that
    /// happened to be on the clipboard beforehand. The user consented to what
    /// they copy NEXT, and what is already there could be anything — including
    /// the password they pasted a minute ago into a field.
    init(startingFrom board: some ClipboardBoard) {
        self.lastChangeCount = board.changeCount
    }

    /// Judge `board` once.
    ///
    /// `lastChangeCount` advances on EVERY outcome, capture or skip — a board
    /// that was skipped must not be re-examined on the next tick. Without that,
    /// a concealed password sitting on the clipboard would be re-inspected once a
    /// second until it was replaced, and the noImage case would re-read bytes
    /// forever while the user is simply working with copied text.
    mutating func evaluate(_ board: some ClipboardBoard) -> ClipboardDecision {
        let count = board.changeCount
        // `!=` rather than `>`: the counter is monotonic within a boot, but the
        // watcher's job here is "is this the same board I already judged?", and
        // that question has one honest form.
        guard count != lastChangeCount else { return .skip(.unchanged) }
        lastChangeCount = count

        let types = Set(board.availableTypes)
        // Markers before bytes, always.
        if types.contains(Self.concealedType) { return .skip(.concealed) }
        if types.contains(Self.transientType) { return .skip(.transient) }
        if types.contains(AssetDragPayload.pasteboardType) { return .skip(.ownCopy) }

        for type in Self.imageTypes {
            if let data = board.data(forType: type), !data.isEmpty {
                return .capture(data)
            }
        }
        return .skip(.noImage)
    }
}

// MARK: - The real pasteboard

/// ``ClipboardBoard`` over a real `NSPasteboard`.
///
/// Not unit-tested by design (the file header says why): it is a wrapper with no
/// decisions in it, and the one interesting choice — reporting the union of every
/// item's types — is documented on the protocol. `NSPasteboard.types` describes
/// only the first item, so a marker riding on a second item would be invisible to
/// it; a multi-item board is exactly the shape a "copy" from a utility app takes.
struct SystemClipboardBoard: ClipboardBoard {
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    var availableTypes: [NSPasteboard.PasteboardType] {
        var all = Set(pasteboard.types ?? [])
        for item in pasteboard.pasteboardItems ?? [] {
            all.formUnion(item.types)
        }
        return Array(all)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.data(forType: type)
    }
}

// MARK: - Provenance

/// The frontmost application at the moment a copy was NOTICED — the watcher's
/// best guess at where an ambient capture came from (013 · B, "provenance is
/// never null").
///
/// Both fields are optional at this layer and stay raw: normalization and the
/// "Clipboard" fallback live in one place,
/// ``DirectInputReader/clipboardInput(imageData:appName:appBundleID:into:at:)``,
/// so there is exactly one definition of what an unknown app is called.
struct FrontmostApp: Equatable {
    var name: String?
    var bundleID: String?

    /// Ask the workspace who is in front.
    ///
    /// **This races the copy and is documented as best-effort, not as a fact.**
    /// The watcher polls, so this runs up to one interval AFTER ⌘C; a user who
    /// copies in Safari and ⌘-tabs to Mail inside that window gets an item
    /// attributed to Mail. There is no API that reports "who owned the pasteboard
    /// when it changed", so the choice is between a good guess and no provenance
    /// at all — and no provenance is worse.
    static func current(_ workspace: NSWorkspace = .shared) -> FrontmostApp {
        let app = workspace.frontmostApplication
        return FrontmostApp(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
}
