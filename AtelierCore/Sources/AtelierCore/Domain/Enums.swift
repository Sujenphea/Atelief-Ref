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
/// Extensible later (`gif`, `audio`, …) without a relationship migration.
public enum AssetKind: String, Sendable, Codable, CaseIterable, Hashable {
    case image
    case video
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
    case web
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
