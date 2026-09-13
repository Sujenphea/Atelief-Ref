// Atelier Capture — rednote video-stream ladder tests (098 T6b, K4).
//
// The live capture (`resources/rednote-note-video.json`, 2026-09-14 — the one artifact 098
// had never had) is sanitized into `test/fixtures/rednote-note-video.json` and drives every
// test that CAN be driven by it. That is fewer than it looks: the capture has ONE populated
// bucket, so it fixes the rung-level shape and says nothing at all about the ordering
// BETWEEN buckets. The table below supplies the rest, and is labelled where it is inventing
// a shape rather than reproducing one.
//
// Two properties are asserted on the FIXTURE'S INPUT rather than on our output, because
// three separate agents have now shipped a rednote fixture that proved the opposite of what
// it claimed (483 the CDN host, 485 the `!transform` suffix, 487 the signing-prefix shape):
// the stream url must still be an UNSIGNED `/stream/…` path on a `sns-v*` host, and its
// `_<n>` suffix must still agree with the rung's `stream_type`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  STREAM_BUCKET_ORDER, STREAM_REFUSAL, isUndecodableCodec, selectStreamRung, videoCandidates,
  videoLadder, withVideoCandidates,
} from "../src/rednote-video.js";
import { toRednoteOriginal } from "../src/extractors/rednote.js";
import { runSweep, OUTCOMES } from "../src/bulk-engine.js";

const live = JSON.parse(readFileSync(new URL("./fixtures/rednote-note-video.json", import.meta.url), "utf8"));
const liveCard = live.data.items[0].note_card;
const liveLadder = videoLadder(liveCard);

/** A rung with the real key names. Defaults are the live rung's shape; every test states
 * only the field it is about. */
const rung = (over = {}) => ({
  video_codec: "EF4", stream_type: 258, format: "mp4", width: 720, height: 960,
  size: 9443827, avg_bitrate: 992337, duration: 76134, default_stream: 0,
  master_url: "http://sns-v11.rednotecdn.com/stream/1/110/258/aaa_258.mp4",
  backup_urls: ["http://sns-v27.rednotecdn.com/stream/1/110/258/aaa_258.mp4"],
  ...over,
});

/** A ladder with the real four buckets, empty unless named. The live capture's own key
 * order is EF5, EF7, EF4, EF6 — deliberately NOT the preference order. */
const ladder = (over = {}) => ({ EF5: [], EF7: [], EF4: [], EF6: [], ...over });

// MARK: - the live capture

test("the live video note selects its one populated bucket's one rung", () => {
  const selected = selectStreamRung(liveLadder);
  assert.equal(selected.ok, true);
  assert.equal(selected.bucket, "EF4");
  assert.equal(selected.index, 0);
  assert.equal(selected.rung.streamType, liveLadder.EF4[0].stream_type);
  assert.equal(selected.rung.format, "mp4");
});

test("the live capture is the shape this file was written against", () => {
  // Asserted so a re-capture that changes the premise fails HERE, with a name, rather than
  // silently making every table below a test of an invented shape.
  assert.equal(liveCard.type, "video");
  assert.equal(liveCard.image_list.length, 1, "a video note carries ONE image: the poster");
  assert.deepEqual(Object.keys(liveLadder).sort(), ["EF4", "EF5", "EF6", "EF7"]);
  assert.equal(liveLadder.EF4.length, 1);
  for (const empty of ["EF5", "EF6", "EF7"]) {
    assert.deepEqual(liveLadder[empty], [], `${empty} is empty — the ordering below is UNTESTED against live data`);
  }
  assert.notDeepEqual(Object.keys(liveLadder), STREAM_BUCKET_ORDER,
    "the capture's key order must differ from the preference order, or key-order selection would pass by luck");
});

test("the live stream url is still an UNSIGNED /stream/ path on a video shard", () => {
  // The vacuity guard. `toRednoteOriginal` rewrites only SIGNED rednotecdn urls, and 487
  // fixed it to leave these alone; a fixture flattened to `/00/00/00/00/SAMPLE.mp4` would
  // still pass through, so passthrough alone proves nothing — the PATH SHAPE is asserted.
  const entry = liveLadder.EF4[0];
  for (const url of [entry.master_url, ...entry.backup_urls]) {
    const { hostname, pathname } = new URL(url);
    assert.match(hostname, /^sns-v\d+\.rednotecdn\.com$/, `not a rednote video shard: ${url}`);
    assert.equal(pathname.split("/").filter(Boolean)[0], "stream",
      `the unsigned /stream/ route must survive sanitization: ${url}`);
    assert.match(pathname, /\.mp4$/);
    assert.equal(toRednoteOriginal(url), url, "an unsigned stream url must be left alone (487)");
  }
});

test("the live rung's url suffix still agrees with its stream_type", () => {
  // 020's undecodable manual pick was a `_330`; this one is a `_258`. The suffix is the only
  // place the discriminator appears in a url, so a sanitizer that dropped it would take the
  // stream_type hypothesis out of reach of any future evidence.
  const entry = liveLadder.EF4[0];
  for (const url of [entry.master_url, ...entry.backup_urls]) {
    assert.match(url, new RegExp(`_${entry.stream_type}\\.mp4$`), url);
  }
});

test("the live rung's backups are DISTINCT urls, and the master comes first", () => {
  const { candidates } = videoCandidates(liveLadder);
  const entry = liveLadder.EF4[0];
  assert.ok(entry.backup_urls.length > 0, "the fixture must actually carry backups");
  assert.equal(candidates[0], entry.master_url);
  assert.deepEqual(candidates.slice(1), entry.backup_urls);
  assert.equal(new Set(candidates).size, candidates.length);
});

test("the ladder is read from the structured form, never from media_v2", () => {
  // `video.media_v2` is a JSON STRING duplicating the whole media object. The sanitizer
  // treats it as the long free text it looks like, so in the fixture it is a placeholder —
  // which makes this enforceable rather than advisory: a parser that reached for media_v2
  // would find nothing, and the assertions above would all be empty.
  assert.equal(typeof liveCard.video.media_v2, "string");
  assert.throws(() => JSON.parse(liveCard.video.media_v2),
    "media_v2 is a placeholder in the fixture — anything reading it would parse nothing");
  assert.ok(videoLadder(liveCard), "the structured ladder is still readable");
});

test("videoLadder is null for a note with no video, and for a non-object stream", () => {
  // Including the one that matters: a card carrying media_v2 and NOTHING structured still
  // yields no ladder. Asserted directly, because "the fixture's media_v2 is a placeholder"
  // only catches a parser that reads it INSTEAD of the structured form, never one that
  // falls back to it — and a fallback is the shape this rot would actually take.
  assert.equal(videoLadder({ video: { media_v2: JSON.stringify({ stream: { EF4: [{ format: "mp4", master_url: "http://h/a.mp4" }] } }) } }), null);
  assert.equal(videoLadder({ type: "normal", image_list: [] }), null);
  assert.equal(videoLadder({ video: {} }), null);
  assert.equal(videoLadder({ video: { media: { stream: [] } } }), null, "an array is not a bucket map");
  assert.equal(videoLadder(null), null);
});

// MARK: - refusals (each one is a typed skip, never a sweep failure)

test("an absent ladder refuses with no_ladder", () => {
  for (const input of [null, undefined, "", 7, ["EF4"]]) {
    assert.deepEqual(selectStreamRung(input), { ok: false, reason: STREAM_REFUSAL.noLadder }, String(input));
  }
});

test("a ladder whose every bucket is empty refuses with empty_ladder", () => {
  assert.deepEqual(selectStreamRung(ladder()), { ok: false, reason: STREAM_REFUSAL.emptyLadder });
  assert.deepEqual(selectStreamRung({}), { ok: false, reason: STREAM_REFUSAL.emptyLadder });
});

test("a rung with no url at all is not a candidate", () => {
  const none = selectStreamRung(ladder({ EF4: [rung({ master_url: "", backup_urls: [] })] }));
  assert.deepEqual(none, { ok: false, reason: STREAM_REFUSAL.noUsableRung });
});

test("a rung with no master_url still counts — its backups are the candidates", () => {
  const backup = "http://sns-v27.rednotecdn.com/stream/1/110/258/bbb_258.mp4";
  const { candidates, refusal } = videoCandidates(
    ladder({ EF4: [rung({ master_url: null, backup_urls: [backup] })] }));
  assert.equal(refusal, null);
  assert.deepEqual(candidates, [backup]);
});

test("a non-mp4 container is skipped, and an mp4-less ladder refuses", () => {
  // `/ingest-video` takes raw bytes, so a manifest is not ingestable — the rule
  // `pinterest-video.js` applies when it filters `videoUrls` down to `.mp4`.
  const hls = rung({ format: "m3u8", master_url: "http://sns-v11.rednotecdn.com/stream/1/110/330/c.m3u8" });
  assert.deepEqual(selectStreamRung(ladder({ EF4: [hls] })),
    { ok: false, reason: STREAM_REFUSAL.noUsableRung });
  const mixed = selectStreamRung(ladder({ EF4: [hls, rung()] }));
  assert.equal(mixed.ok, true);
  assert.equal(mixed.index, 1, "the mp4 rung is taken even though it is second");
});

test("with no `format` field the url extension decides", () => {
  const mp4 = rung({ format: undefined });
  assert.equal(selectStreamRung(ladder({ EF4: [mp4] })).ok, true);
  const opaque = rung({ format: undefined, master_url: "http://sns-v11.rednotecdn.com/stream/1/110/330/d", backup_urls: [] });
  assert.deepEqual(selectStreamRung(ladder({ EF4: [opaque] })),
    { ok: false, reason: STREAM_REFUSAL.noUsableRung }, "neither field nor extension says mp4 → dropped, not guessed");
});

// MARK: - the ef51 rule, and the EF-bucket confusion it is NOT

test("a fourcc is four characters; a bucket label is three", () => {
  // 020's rule is about the fourcc in the MP4 SAMPLE ENTRY (`ef51`), not about the
  // confusingly EF-prefixed bucket names. Refusing `EF4` would refuse every rung rednote
  // has ever sent — which is why the live capture above selects rather than refuses.
  assert.equal(isUndecodableCodec("ef51"), true);
  assert.equal(isUndecodableCodec("EF51"), true);
  assert.equal(isUndecodableCodec("EF4"), false);
  assert.equal(isUndecodableCodec("EF7"), false);
  assert.equal(isUndecodableCodec("avc1"), false);
  assert.equal(isUndecodableCodec(null), false);
});

test("an ef*-ONLY ladder refuses with undecodable_codec — cover-still, not a failure", () => {
  // 020's Risks entry, by name: "some notes may offer only ef* rungs. Then the honest
  // outcome is cover-still-only for that note; record it as a typed skip, do not fail the
  // sweep." INVENTED SHAPE — no capture has ever carried a fourcc in `video_codec`.
  const only = ladder({ EF4: [rung({ video_codec: "ef51" })], EF5: [rung({ video_codec: "ef52" })] });
  assert.deepEqual(selectStreamRung(only), { ok: false, reason: STREAM_REFUSAL.undecodableCodec });
  const { candidates, refusal } = videoCandidates(only);
  assert.deepEqual(candidates, [], "nothing is offered to the ingest path");
  assert.equal(refusal, STREAM_REFUSAL.undecodableCodec);
});

test("an ef* rung beside a usable one is dropped, not refused", () => {
  const mixed = ladder({
    EF4: [rung({ video_codec: "ef51", master_url: "http://sns-v11.rednotecdn.com/stream/1/110/330/bad_330.mp4", backup_urls: [] })],
    EF5: [rung({ video_codec: "EF5", master_url: "http://sns-v11.rednotecdn.com/stream/1/110/258/good_258.mp4", backup_urls: [] })],
  });
  const selected = selectStreamRung(mixed);
  assert.equal(selected.ok, true);
  assert.equal(selected.bucket, "EF5");
  assert.deepEqual(videoCandidates(mixed).candidates,
    ["http://sns-v11.rednotecdn.com/stream/1/110/258/good_258.mp4"]);
});

// MARK: - ordering (the contract T6c's rung-advance walks)

test("buckets are taken in STREAM_BUCKET_ORDER, not in the object's key order", () => {
  const out = selectStreamRung({
    EF7: [rung({ video_codec: "EF7" })], EF5: [rung({ video_codec: "EF5" })],
    EF4: [rung({ video_codec: "EF4" })], EF6: [rung({ video_codec: "EF6" })],
  });
  assert.equal(out.bucket, "EF4");
  assert.deepEqual(videoCandidates({ EF7: [rung({ master_url: "http://h/7.mp4", backup_urls: [] })],
    EF5: [rung({ master_url: "http://h/5.mp4", backup_urls: [] })] }).candidates,
    ["http://h/5.mp4", "http://h/7.mp4"]);
});

test("selection is by CODEC BUCKET, never by size — 020 rule 1", () => {
  // The rule learned by getting it wrong: taking the largest file is what landed the manual
  // run on the undecodable ef51 rung. The later bucket here is bigger on every dimension a
  // size-greedy selector could reach for.
  const small = rung({ size: 100, avg_bitrate: 1, width: 320, height: 480, master_url: "http://h/small.mp4", backup_urls: [] });
  const huge = rung({ size: 99_000_000, avg_bitrate: 9_000_000, width: 1080, height: 1920, master_url: "http://h/huge.mp4", backup_urls: [] });
  const across = ladder({ EF4: [small], EF6: [huge] });
  const out = selectStreamRung(across);
  assert.equal(out.bucket, "EF4");
  assert.equal(out.rung.urls[0], "http://h/small.mp4");
  // The CANDIDATE ORDER carries the same rule — a size sort applied after bucket ordering
  // would leave `selectStreamRung` looking right and still hand the 422 walk the big rung
  // first, which is exactly how 020's manual run reached the undecodable file.
  assert.deepEqual(videoCandidates(across).candidates, ["http://h/small.mp4", "http://h/huge.mp4"]);
  // …and within one bucket, rednote's own array order wins over size too.
  const within = ladder({ EF4: [small, huge] });
  assert.equal(selectStreamRung(within).index, 0);
  assert.deepEqual(videoCandidates(within).candidates, ["http://h/small.mp4", "http://h/huge.mp4"]);
});

test("an unknown bucket name is ordered last but never dropped", () => {
  const known = rung({ master_url: "http://h/known.mp4", backup_urls: [] });
  const novel = rung({ video_codec: "EF9", master_url: "http://h/novel.mp4", backup_urls: [] });
  assert.deepEqual(videoCandidates({ EF9: [novel], EF4: [known] }).candidates,
    ["http://h/known.mp4", "http://h/novel.mp4"]);
  // Alone, it is still tried: a bucket we have never seen is more likely a new codec
  // generation than a broken one, and the 422 is cheaper than refusing content outright.
  const alone = selectStreamRung({ EF9: [novel] });
  assert.equal(alone.ok, true);
  assert.equal(alone.bucket, "EF9");
});

test("within a rung the order is master then backups, deduped", () => {
  const master = "http://sns-v11.rednotecdn.com/stream/1/110/258/x_258.mp4";
  const other = "http://sns-v27.rednotecdn.com/stream/1/110/258/x_258.mp4";
  const plan = ladder({ EF4: [rung({ master_url: master, backup_urls: [master, other] })] });
  const { candidates, rungs } = videoCandidates(plan);
  assert.deepEqual(candidates, [master, other], "a backup repeating the master must not buy a retry of a url that just failed");
  // …at the RUNG level too, not only after the flat list is deduped: `selectStreamRung`
  // hands `rung.urls` straight to the caller, and that is the list a within-rung advance
  // walks before it moves on to the next rung.
  assert.deepEqual(rungs[0].urls, [master, other]);
  assert.deepEqual(selectStreamRung(plan).rung.urls, [master, other]);
});

test("a rung contributes SEVERAL candidates, so the list is longer than the ladder", () => {
  // What D5 could not know: it assumed candidates would be synthesised from rung ordering
  // alone. `backup_urls[]` means exhausting the list is not the same as exhausting the
  // ladder, and a 422 must advance WITHIN a rung before it advances between rungs.
  const { candidates, rungs } = videoCandidates(ladder({
    EF4: [rung({ master_url: "http://h/a.mp4", backup_urls: ["http://h/a2.mp4"] })],
    EF5: [rung({ master_url: "http://h/b.mp4", backup_urls: ["http://h/b2.mp4"] })],
  }));
  assert.equal(rungs.length, 2);
  assert.deepEqual(candidates, ["http://h/a.mp4", "http://h/a2.mp4", "http://h/b.mp4", "http://h/b2.mp4"]);
});

test("non-http entries are dropped from a rung's urls", () => {
  const { candidates } = videoCandidates(ladder({
    EF4: [rung({ master_url: "//sns-v11.rednotecdn.com/stream/1/110/258/p_258.mp4", backup_urls: [null, 7, "http://h/ok.mp4"] })],
  }));
  assert.deepEqual(candidates, ["http://h/ok.mp4"]);
});

test("every rung carries its stream_type for the 422 to report against", () => {
  // Carried, never sorted on: the "stream_type is the real discriminator" hypothesis is one
  // good sample (258) and one bad one (020's _330), which is not enough to select on. This
  // is how it would ever earn more evidence.
  const { rungs } = videoCandidates(liveLadder);
  assert.deepEqual(rungs.map((r) => r.streamType), [258]);
  const noType = videoCandidates(ladder({ EF4: [rung({ stream_type: "258" })] }));
  assert.equal(noType.rungs[0].streamType, null, "a non-numeric stream_type is reported as absent, not coerced");
  assert.equal(noType.candidates.length, 2, "…and it does not affect selection");
});

// MARK: - 020 rule 3: never checkpoint a stream list

test("an attached candidate list survives property access and NOTHING else", () => {
  const item = withVideoCandidates({ sourceId: "n1", cursor: "c1" }, liveLadder);
  assert.deepEqual([...item.videoCandidates], videoCandidates(liveLadder).candidates);
  assert.equal(item.videoRefusal, null);
  // The three ways a sweep could persist or ship an item — all copy own ENUMERABLE
  // properties only, so all of them drop it.
  assert.equal(JSON.parse(JSON.stringify(item)).videoCandidates, undefined);
  assert.equal(structuredClone(item).videoCandidates, undefined);
  assert.equal({ ...item }.videoCandidates, undefined);
  assert.deepEqual(Object.keys(item), ["sourceId", "cursor"]);
  assert.throws(() => { item.videoCandidates = ["http://evil"]; }, "the list is not writable");
  assert.throws(() => item.videoCandidates.push("http://evil"), "the list is frozen");
});

test("a refused ladder attaches an EMPTY list and the reason", () => {
  const item = withVideoCandidates({ sourceId: "n2" }, ladder());
  assert.deepEqual([...item.videoCandidates], []);
  assert.equal(item.videoRefusal, STREAM_REFUSAL.emptyLadder);
});

test("no stream url can reach a checkpoint, driven through the real engine", () => {
  // 020 B3: the same note offered a DIFFERENT ladder on two visits minutes apart, so a
  // checkpointed master_url comes back 404 or hands over a bad rung. This runs the actual
  // `runSweep` checkpoint path over items carrying attached candidates and asserts every
  // byte it saved.
  const saves = [];
  const storage = { async load() { return null; }, async save(key, value) { saves.push(value); } };
  const items = [1, 2, 3].map((n) => withVideoCandidates(
    { sourceId: `n${n}`, mediaUrl: `http://sns-i27.rednotecdn.com/k${n}`, cursor: `cur-${n}`,
      provenance: { platform: "rednote", rawMetadata: { noteId: `n${n}` } } }, liveLadder));
  const driver = { enumerate: () => (async function* () { for (const it of items) yield it; })() };

  return runSweep(driver, "board:x", {
    relay: async () => ({ outcome: OUTCOMES.ingested }),
    storage, checkpointKey: "ck", sleep: async () => {}, random: () => 0,
  }).then((result) => {
    assert.equal(result.status, "complete");
    assert.ok(saves.length > 0, "the sweep must actually have checkpointed, or this proves nothing");
    const streamUrls = videoCandidates(liveLadder).candidates;
    assert.ok(streamUrls.length > 0);
    for (const saved of saves) {
      const text = JSON.stringify(saved);
      for (const url of streamUrls) {
        assert.equal(text.includes(url), false, `a stream url reached the checkpoint: ${text}`);
      }
      assert.equal(text.includes("rednotecdn.com/stream/"), false, `a stream path reached the checkpoint: ${text}`);
    }
  });
});
