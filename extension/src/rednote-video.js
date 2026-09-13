// Atelier Capture — rednote video-stream ladder: which rung, and in what order (098 T6b, K4).
//
// The shape of the other two platforms' video resolution, minus the half rednote does not
// need. `pinterest-video.js` and `twitter-video.js` each pair a PURE selector (tested
// against a saved payload) with a thin fetch wrapper, because on those platforms the
// variant list has to be gone and got — Pinterest's lives in the pin page's SEO HTML,
// X's behind a syndication call. rednote's arrives on its own: the note-detail response
// the SPA already fetched and `hook-core.js` already forwarded carries the whole ladder
// (098 D1 — we never issue a rednote request, so there is nothing here to wrap). What is
// left is the selector, and the selector is the part that was always pure.
//
// Verified against ONE live capture, `resources/rednote-note-video.json` (2026-09-14),
// sanitized into `test/fixtures/rednote-note-video.json`. What that capture actually shows,
// stated plainly because most of this file's preference ORDER is not covered by it:
//
//   note_card.video.media.stream = { EF4: [1 rung], EF5: [], EF6: [], EF7: [] }
//
// ONE populated bucket. The single EF4 rung is `stream_type: 258`, `format: "mp4"`,
// 720x960, and its `master_url` — `http://sns-v11.rednotecdn.com/stream/1/110/258/<id>_258.mp4`
// — is served ALREADY UNSIGNED and was fetched live: 206, `video/mp4`. It also carries one
// `backup_urls[]` entry: the same path on a different shard host. So the rung-level shape
// is verified; the ordering BETWEEN buckets is not, and cannot be until a note turns up
// with two of them populated.
//
// THE `ef51` TRAP, which is easy to re-derive backwards. 020's manual run took the largest
// file, landed on a `_330` variant, and could not decode it: the MP4 sample entry's fourcc
// was `ef51`, an obfuscated stream only rednote's own player reads (relabelled `hvc1` it
// still fails — `vps_reserved_three_2bits is not three`, `PPS id out of range`). That
// fourcc lives in the MP4 BYTES. It is NOT the `EF4`/`EF5`/`EF6`/`EF7` bucket name, which
// is also `EF`-prefixed and means something else entirely. A selector that refused `EF*`
// labels would refuse every rung rednote has ever sent. See `isUndecodableCodec`.
//
// So: this file cannot see a fourcc, and says so rather than pretending. The real
// undecodable-rung signal is the HTTP 422 from `/ingest-video` (020 B2), which is why the
// headline export is an ORDERED LIST and not a single answer — T6c walks it.

/** The bucket preference order, and the one judgement call in this file.
 *
 * **Only `EF4` has ever been observed populated**, in the only `type: "video"` capture that
 * exists, and its `master_url` is the only rednote stream verified to serve a decodable
 * mp4. Ascending order therefore puts the one known-good bucket first; the ordering among
 * `EF5`/`EF6`/`EF7` is a GUESS and is untested against live data.
 *
 * The guess, so a reader can weigh it: `EF<n>` looks like a codec-generation index, and on
 * every other platform the lower generation is the more universally decodable one —
 * `pinterest-video.js` prefers H.264 (`/expMp4/`) over HEVC for exactly that reason. That
 * correspondence is unverified here. It costs a 422 and one rung-advance if it is wrong,
 * which is precisely the cost the ladder was built to absorb.
 *
 * NOT the JSON's own key order, which in the live capture is `EF5, EF7, EF4, EF6` — an
 * object's key order is not a preference and a selector that took `Object.keys` would have
 * picked an empty bucket first. */
export const STREAM_BUCKET_ORDER = ["EF4", "EF5", "EF6", "EF7"];

/** Why a ladder yielded nothing. A TYPED refusal, never `null`: every one of these means
 * "keep this note's cover still and record a skip", and the sweep must be able to say
 * which (020's Risks entry — an `ef*`-only note is cover-still-only, and must NOT fail the
 * sweep). The vocabulary mirrors `parseNoteDetail`'s `unsupported` strings. */
export const STREAM_REFUSAL = {
  /** No `video.media.stream` at all — not a video note, or the path moved. */
  noLadder: "no_ladder",
  /** The ladder is there and every bucket is empty (as `EF5`/`EF6`/`EF7` are today). */
  emptyLadder: "empty_ladder",
  /** Rungs exist, but none is a fetchable mp4 — no url, or a non-mp4 container. */
  noUsableRung: "no_usable_rung",
  /** Every fetchable mp4 rung is labelled with an `ef??` fourcc. 020's cover-still-only
   * case, at the only layer where JSON could ever declare it. */
  undecodableCodec: "undecodable_codec",
};

/** The ladder off a `note_card`, or null.
 *
 * **Read the structured form; never `media_v2`.** `video.media_v2` is a JSON *string*
 * duplicating this whole object — two representations of the same data, and the string one
 * is the one that will rot silently. (487 found rednote's subtitle urls are reachable only
 * from inside it; that is a reason to leave it alone, not to start parsing it.) The
 * committed fixture makes the rule enforceable rather than advisory: the sanitizer replaces
 * `media_v2` with `"Sample text N"` — free text, like any other long string — so a parser
 * that reached for it would produce nothing at all against the fixture. */
export function videoLadder(noteCard) {
  const media = noteCard && noteCard.video && noteCard.video.media;
  const stream = media && media.stream;
  return stream && typeof stream === "object" && !Array.isArray(stream) ? stream : null;
}

/**
 * True for a codec label we refuse to hand to the ingest path.
 *
 * A FOURCC is four characters (`avc1`, `hvc1`, and 020's undecodable `ef51`). A rednote
 * stream BUCKET is three (`EF4`…`EF7`). That length difference is the whole disambiguation,
 * and it is the reason this predicate can encode 020's "treat `ef*` fourccs as unusable"
 * without refusing every rung rednote sends.
 *
 * Honest about its own standing: **no capture has ever carried a label this matches.**
 * `video_codec` is `"EF4"` in the one sample that exists, so this branch is exercised by
 * the table test and by nothing else. It is a forward guard for the day rednote puts the
 * real fourcc in the JSON — and it is deliberately applied to `video_codec` only, never to
 * the bucket name, so a future bucket called `EF51` is not mistaken for a fourcc.
 *
 * The residual risk is stated rather than hidden: if rednote ever names a genuine codec
 * with a four-character `ef??` label, we refuse a rung we could have taken and the note
 * degrades to its cover still. That is the failure direction 020 calls the honest one; the
 * opposite error — shipping an undecodable file — is what the 422 backstop is for.
 */
export function isUndecodableCodec(codec) {
  return typeof codec === "string" && /^ef[0-9a-f]{2}$/i.test(codec);
}

/** Every url a rung offers, in the order it offers them: `master_url` first, then each
 * `backup_urls[]` entry. That per-rung order is not a preference we invented — it is
 * rednote's own, and the backups are the same object on other CDN shards (the live rung's
 * master is `sns-v11`, its one backup `sns-v27`, same path). Deduped, because a rung that
 * repeats its master in `backup_urls` would otherwise buy the rung-advance a retry against
 * a url that just failed. */
function rungUrls(rung) {
  const backups = Array.isArray(rung.backup_urls) ? rung.backup_urls : [];
  const urls = [rung.master_url, ...backups]
    .filter((url) => typeof url === "string" && /^https?:\/\//.test(url));
  return [...new Set(urls)];
}

/** Whether a rung is a fetchable MP4. `/ingest-video` takes raw bytes, so an HLS/DASH
 * manifest is not ingestable — the same rule `pinterest-video.js` applies when it filters
 * `videoUrls` down to `.mp4`. `format` is authoritative when present; when it is absent the
 * url's extension answers, and when neither says anything the rung is dropped rather than
 * guessed at. */
function isMp4Rung(rung, urls) {
  if (rung.format != null && rung.format !== "") return String(rung.format).toLowerCase() === "mp4";
  return urls.some((url) => /\.mp4(?:$|[?#])/i.test(url));
}

/**
 * Every rung of a ladder, flattened into ONE ordered list.
 *
 * Across buckets: `STREAM_BUCKET_ORDER`, then any bucket name we have never seen, in the
 * object's own key order. An unknown bucket is ordered LAST but is never dropped — it has
 * never been observed, so it cannot outrank a bucket that has, but refusing content
 * outright is a worse trade than one 422 against it.
 *
 * Within a bucket: rednote's own array order. **Not size, not bitrate, not resolution** —
 * 020's rule 1, learned by getting it wrong: taking the largest file is what landed the
 * manual run on the undecodable `ef51` rung, and falling back to an h264 rung cost
 * resolution only (same duration, same content). The fixture makes that rule hard to
 * un-learn by accident: `size` is ≥ 1,000,000, so the sanitizer replaced it with a
 * synthetic number, and a selector that sorted on it would be sorting on noise.
 *
 * `stream_type` is CARRIED and never sorted on. The hypothesis that the numeric type is
 * the real pre-download codec discriminator (this capture's working rung is 258; 020's
 * undecodable one was `_330`) is one good sample and one bad one — far too thin to hang
 * selection on, and there is no JSON signal thin enough to trust over the 422 anyway. It
 * rides on each rung so T6c's rung-advance can report which types 422'd, which is how the
 * hypothesis would ever earn a promotion.
 */
function orderRungs(ladder) {
  const names = Object.keys(ladder);
  const ordered = [
    ...STREAM_BUCKET_ORDER.filter((name) => names.includes(name)),
    ...names.filter((name) => !STREAM_BUCKET_ORDER.includes(name)),
  ];
  const rungs = [];
  for (const bucket of ordered) {
    const entries = Array.isArray(ladder[bucket]) ? ladder[bucket] : [];
    entries.forEach((entry, index) => {
      if (!entry || typeof entry !== "object") return;
      const urls = rungUrls(entry);
      rungs.push({
        bucket,
        index,
        urls,
        codec: entry.video_codec != null ? String(entry.video_codec) : null,
        streamType: Number.isFinite(entry.stream_type) ? entry.stream_type : null,
        format: entry.format != null ? String(entry.format) : null,
        width: entry.width ?? null,
        height: entry.height ?? null,
        usable: urls.length > 0 && isMp4Rung(entry, urls),
      });
    });
  }
  return rungs;
}

/** The usable, decodable rungs of a ladder in preference order, or the typed refusal that
 * explains why there are none. The one piece of reasoning both public entry points need —
 * `selectStreamRung` is its head, `videoCandidates` is its urls — so it is computed once
 * here rather than derived twice from the raw ladder. */
function planLadder(ladder) {
  if (!ladder || typeof ladder !== "object" || Array.isArray(ladder)) {
    return { rungs: [], refusal: STREAM_REFUSAL.noLadder };
  }
  const rungs = orderRungs(ladder);
  if (rungs.length === 0) return { rungs: [], refusal: STREAM_REFUSAL.emptyLadder };

  const fetchable = rungs.filter((rung) => rung.usable);
  if (fetchable.length === 0) return { rungs: [], refusal: STREAM_REFUSAL.noUsableRung };

  const decodable = fetchable.filter((rung) => !isUndecodableCodec(rung.codec));
  // Reported ahead of `noUsableRung` would be wrong: "there were mp4s and every one of them
  // is an obfuscated stream" is a different note from "there was nothing to fetch", and 020
  // asks for the first one by name.
  if (decodable.length === 0) return { rungs: [], refusal: STREAM_REFUSAL.undecodableCodec };
  return { rungs: decodable, refusal: null };
}

/**
 * The rung to try FIRST, or a typed refusal.
 *
 * `{ ok: true, bucket, index, rung }` — `rung` is the descriptor `orderRungs` built, with
 * its `urls` already in master-then-backups order.
 * `{ ok: false, reason }` — one of `STREAM_REFUSAL`, never a bare null. The caller's job on
 * a refusal is always the same: keep the cover still the K3a pass already captured, and
 * record the reason as a skip. It is not a sweep failure (020, Risks & edge cases).
 *
 * Pure, table-tested, and deliberately NOT the whole answer — see `videoCandidates`.
 */
export function selectStreamRung(ladder) {
  const { rungs, refusal } = planLadder(ladder);
  if (refusal) return { ok: false, reason: refusal };
  return { ok: true, bucket: rungs[0].bucket, index: rungs[0].index, rung: rungs[0] };
}

/**
 * The ORDERED candidate list the 422 rung-advance walks (098 D5).
 *
 * `{ candidates, rungs, refusal }` — `candidates` is a flat array of url strings, which is
 * the shape `planCapture` already uses for `urlCandidates` (`capture-plan.js`), so T6c adds
 * a field rather than a second convention. `rungs` is the same list one level up, for
 * reporting which rung a 422 came from. `refusal` is null when there is anything to try and
 * a `STREAM_REFUSAL` reason when there is not — in which case `candidates` is empty.
 *
 * Ordering is the contract: **per rung, `master_url` then its `backup_urls[]`; across
 * rungs, `STREAM_BUCKET_ORDER`.** D5 was written expecting the list would have to be
 * synthesised from rung ordering alone; `backup_urls[]` was not known to exist then, and it
 * changes the shape — a rung now contributes several candidates, so exhausting the list is
 * no longer the same thing as exhausting the ladder, and a 422 must advance within a rung
 * before it advances between them.
 */
export function videoCandidates(ladder) {
  const { rungs, refusal } = planLadder(ladder);
  return { candidates: [...new Set(rungs.flatMap((rung) => rung.urls))], rungs, refusal };
}

/**
 * Hang a candidate list on a `BulkItem` in a way a checkpoint CANNOT pick up.
 *
 * 020 B3, the rule this exists for: **never checkpoint a stream list.** The same note
 * offered a DIFFERENT ladder on two visits minutes apart, so a persisted `master_url` comes
 * back 404, or comes back pointing at a rung that is no longer the right one. Re-resolve on
 * resume; the ladder is free, it rides on a response the page fetches anyway.
 *
 * A comment saying "don't persist this" is not a mechanism, so this is structural: the
 * property is defined NON-ENUMERABLE, and every way a sweep could persist or ship an item
 * copies own ENUMERABLE properties only —
 *
 *   · `JSON.stringify(item)`            — what a checkpoint value is serialized by
 *   · `structuredClone(item)`           — what `chrome.storage.local` and `postMessage` use
 *   · `{ ...item }` / `Object.assign`   — what any copy in between uses
 *
 * — so the list is legible to code that asks for it by name (`item.videoCandidates`) and
 * invisible to everything that merely copies the item. It is also frozen and
 * non-configurable, so a second attach on the same item throws instead of silently winning.
 *
 * Recomputing is the primary defence and this is the backstop: `videoCandidates` is a pure
 * function of a response, cheap, and the honest thing to call again on resume.
 */
export function withVideoCandidates(item, ladder) {
  const { candidates, refusal } = videoCandidates(ladder);
  Object.defineProperty(item, "videoCandidates", {
    value: Object.freeze([...candidates]), enumerable: false, writable: false, configurable: false,
  });
  Object.defineProperty(item, "videoRefusal", {
    value: refusal, enumerable: false, writable: false, configurable: false,
  });
  return item;
}
