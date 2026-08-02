// AtelierCore — domain enums
//
// The closed sets of the data model (003 §data-model). Every enum is backed by
// a `String` rawValue: rawValues become the on-disk encoding (decision C5), so
// they are agent-readable and — unlike Int rawValues — survive case reordering
// (003:198, "open-ended" enums). The explicit snake_case strings on multi-word
// cases pin that encoding against accidental edits.
//
// These are plain value types: no persistence, no validation. GRDB conformances
// and the App Services validation funnel are added in later chunks.

/// The medium of a captured ``Asset`` (003 §data-model · Asset.kind).
///
/// `image` / `video` are byte-backed (a `blob_hash`); `tweet` / `link` / `color`
/// are **media-less** kinds (003 · multi-kind) whose substance lives in
/// ``Asset/payload`` — a media-less asset has `blob_hash IS NULL`. The
/// byte-vs-content distinction is derived once by ``AssetContent`` so views
/// switch on content, not on nil bytes. Extensible later (`gif`, `audio`, …)
/// without a relationship migration.
public enum AssetKind: String, Sendable, Codable, CaseIterable, Hashable {
    case image
    case video
    case tweet
    case link
    case color

    /// Whether this kind is backed by blob bytes (`blob_hash` required) or is
    /// media-less (content in ``Asset/payload``, `blob_hash` optional). The
    /// single place the byte/content split is defined — validation and
    /// ``AssetContent`` both read it, so a new kind declares its nature here once.
    public var isByteBacked: Bool {
        switch self {
        case .image, .video: true
        case .tweet, .link, .color: false
        }
    }
}

/// Where a ``Source`` originated (003 §data-model · Source.platform).
///
/// `localPaste` / `localDrag` carry explicit snake_case rawValues so the
/// stored encoding matches the spec's `local_paste` / `local_drag` exactly.
public enum Platform: String, Sendable, Codable, CaseIterable, Hashable {
    case twitter
    case pinterest
    case instagram
    case cosmos
    case rednote
    case web
    /// The opt-in ambient clipboard watcher (013 · K3) — an image copied
    /// ANYWHERE on the system, noticed by polling and filed into Unsorted. Its own
    /// case rather than `localPaste` because the two are different acts: a paste
    /// is a deliberate ⌘V into the app, this one the user never touched the app
    /// for. Keeping them apart is what lets a filter, a search, or a future
    /// "undo everything the watcher took" address exactly the ambient ones.
    case clipboard
    case localPaste = "local_paste"
    case localDrag = "local_drag"
}

/// The download lifecycle of an ``Asset``'s blob (003 §data-model ·
/// Asset.download_state). `failed` is kept with its source for retry, so an
/// import is resumable (003 §ingestion).
public enum DownloadState: String, Sendable, Codable, CaseIterable, Hashable {
    case pending
    case downloaded
    case failed
}

/// Who applied a ``Tag`` (003 §data-model · Tag.source). Agent-written
/// organization is attributed (`agent`) so it stays reviewable and reversible.
public enum TagSource: String, Sendable, Codable, CaseIterable, Hashable {
    case user
    case agent
}

/// How a collection's grid is ordered (007 · sort). Persisted per collection in
/// `collection.sort_mode` (C5 TEXT rawValue), default `.manual`.
///
/// - `.manual`: the user's drag order (`manual_order`, then `id`).
/// - `.newest`: capture-time descending (`created_at DESC, id DESC`).
/// - `.mostViewed`: view counter descending, newest as tie-break
///   (`view_count DESC, created_at DESC, id DESC`).
///
/// Switching modes is non-destructive — `manual_order` is never rewritten, so
/// returning to `.manual` restores the drag arrangement.
public enum SortMode: String, Sendable, Codable, CaseIterable, Hashable {
    case manual
    case newest
    case mostViewed = "most_viewed"
}
