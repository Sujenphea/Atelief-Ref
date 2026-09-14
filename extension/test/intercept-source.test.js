// Atelier Capture — the generic push→pull intercept source, tested AS A SEAM (098 R9/R10).
//
// `intercept-source.js` is what a hook-driven sweep runs on: the response queue, the
// auto-scroll, the stall, the scope filter, `expandItems`, and the fatal-error route.
// Until now it had no test file of its own — every assertion about it lived in
// `twitter-source.test.js` and reached it THROUGH X (X's parser, X's stall subclass, X's
// scope matcher). That left the properties X happens not to exercise unguarded, and
// rednote (098) is about to become the second consumer AND the first user of the fatal
// -error route.
//
// So this file drives the seam directly with fakes, which is exactly what its own header
// invites: "Pure/injectable: `scroll` + `sleep` are deps, so a test drives the whole loop
// with no browser."

import { test } from "node:test";
import assert from "node:assert/strict";

import { createInterceptSource, SourceStallError } from "../src/intercept-source.js";

/** Drain an async iterable into an array. */
async function collect(iterable) {
  const out = [];
  for await (const item of iterable) out.push(item);
  return out;
}

/** A page whose items are just the ids given, for readable assertions. */
const page = (ids, { endOfFeed = false, error = null } = {}) =>
  ({ items: ids.map((id) => ({ sourceId: id })), endOfFeed, error });

/** The identity parser: `onResponse` is handed a page object directly. */
const passthrough = (json) => json;

/** A source with sane test defaults (no real timers, no real scrolling). */
function makeSource(overrides = {}) {
  return createInterceptSource({
    parsePage: passthrough,
    scroll: () => {},
    sleep: async () => {},
    ...overrides,
  });
}

const ids = (items) => items.map((i) => i.sourceId);

// MARK: - construction

test("requires a parsePage — a source with no parser is a programming error, not a silent no-op", () => {
  assert.throws(() => createInterceptSource({}), /requires parsePage/);
});

// MARK: - the queue / scroll / terminate loop

test("yields a response pushed BEFORE enumerate, without scrolling for it", async () => {
  let scrolls = 0;
  const source = makeSource({ scroll: () => { scrolls += 1; } });
  // The replay case: the hook re-emits what it buffered before the sweep attached.
  source.onResponse(page(["a", "b"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a", "b"]);
  // The queue was never empty at the top of the loop, so nothing needed nudging.
  assert.equal(scrolls, 0);
});

test("drains the queue, scrolls for more, and stops on the endOfFeed page", async () => {
  const source = makeSource({
    // Each scroll stands in for the page fetching its next slice.
    scroll: () => {
      if (scrolls === 0) source.onResponse(page(["c"]));
      if (scrolls === 1) source.onResponse(page(["d"], { endOfFeed: true }));
      scrolls += 1;
    },
  });
  let scrolls = 0;
  source.onResponse(page(["a", "b"]));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a", "b", "c", "d"]);
  assert.equal(scrolls, 2);
});

test("a page after endOfFeed is never reached — the feed is done when it says it is", async () => {
  const source = makeSource();
  source.onResponse(page(["a"], { endOfFeed: true }));
  source.onResponse(page(["b"]));   // queued, but the iterator returns first

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

// MARK: - the stall (a wall is NOT an end)

test("throws the injected StallError after maxIdleRounds of fruitless scrolling", async () => {
  class MyStall extends SourceStallError {
    constructor(rounds) { super(rounds, "my feed"); this.name = "MyStall"; }
  }
  const source = makeSource({ maxIdleRounds: 3, StallError: MyStall });

  // A stall must NOT look like a clean finish: the engine halts RESUMABLE on a throw,
  // and would falsely record the feed complete on a plain return.
  const error = await collect(source.enumerate()).then(() => null, (e) => e);
  assert.ok(error instanceof MyStall, `expected MyStall, got ${error}`);
  assert.equal(error.stalled, true);
  assert.equal(error.idleRounds, 3);
});

test("the default stall error names the source and reports its round count", async () => {
  const source = makeSource({ maxIdleRounds: 1 });
  const error = await collect(source.enumerate()).then(() => null, (e) => e);
  assert.ok(error instanceof SourceStallError);
  assert.match(error.message, /source stalled: no new page after 1 scroll/);
});

test("items already yielded survive a stall that follows them", async () => {
  const seen = [];
  const source = makeSource({ maxIdleRounds: 2 });
  source.onResponse(page(["a", "b"]));   // real items, then the wall

  await assert.rejects(async () => {
    for await (const item of source.enumerate()) seen.push(item.sourceId);
  }, SourceStallError);
  assert.deepEqual(seen, ["a", "b"]);
});

test("the idle counter RESETS after a productive scroll, so a slow feed is not a stall", async () => {
  let scrolls = 0;
  const seen = [];
  const source = makeSource({
    maxIdleRounds: 2,
    // idle, PAGE, idle, idle → stalls on the 4th scroll. Had the counter not reset, the
    // one idle round before the page plus the one after would have tripped the limit on
    // the 3rd — so the scroll count is what actually proves the reset happened.
    scroll: () => {
      scrolls += 1;
      if (scrolls === 2) source.onResponse(page(["a"]));
    },
  });

  const error = await (async () => {
    try {
      for await (const item of source.enumerate()) seen.push(item.sourceId);
      return null;
    } catch (e) { return e; }
  })();
  assert.ok(error instanceof SourceStallError);
  assert.deepEqual(seen, ["a"]);
  assert.equal(scrolls, 4);
});

// MARK: - scope (replay-buffer contamination)

test("with a scope set, a response from another feed is dropped", async () => {
  const source = makeSource({
    scope: "board:99",
    matchesScope: (url, scope) => url === scope,
  });
  source.onResponse(page(["wrong"]), "board:11");
  source.onResponse(page(["right"], { endOfFeed: true }), "board:99");

  assert.deepEqual(ids(await collect(source.enumerate())), ["right"]);
});

test("with NO scope, every response is accepted even when a matcher is supplied", async () => {
  const source = makeSource({
    scope: null,
    matchesScope: () => false,   // would reject everything if it were consulted
  });
  source.onResponse(page(["a"], { endOfFeed: true }), "anywhere");

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

// MARK: - a bad page is not a fatal page

test("a parsePage THROW is ignored — the next good response still drives the sweep", async () => {
  const source = createInterceptSource({
    parsePage: (json) => {
      if (json.boom) throw new Error("unparseable");
      return json;
    },
    scroll: () => {},
    sleep: async () => {},
  });
  source.onResponse({ boom: true });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

test("a parsePage returning nothing queues nothing, and does not wedge the iterator", async () => {
  const source = createInterceptSource({
    parsePage: (json) => (json.skip ? null : json),
    scroll: () => {},
    sleep: async () => {},
    maxIdleRounds: 1,
  });
  source.onResponse({ skip: true });
  // Nothing queued → the loop scrolls, finds nothing, and stalls rather than hanging.
  await assert.rejects(collect(source.enumerate()), SourceStallError);
});

// MARK: - expandItems (098 R7)
//
// The seam K3b depends on entirely, and today reachable only through X's thread
// expander. Its fail-open rule is right for X (a failed TweetDetail costs the replies,
// the bookmarked tweet still saves) and lossy for rednote (a failed note-detail saves 1
// cover instead of 9 images). These tests pin the CURRENT contract so R7's
// `onExpandFailure` can be added on top of a known baseline rather than a guess.

test("expandItems replaces a page's items with what it returns", async () => {
  const source = makeSource({
    expandItems: async (items) => [...items, { sourceId: "extra" }],
  });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a", "extra"]);
});

test("an expandItems THROW degrades to the unexpanded page — never fatal to the sweep", async () => {
  const source = makeSource({
    expandItems: async () => { throw new Error("detail fetch failed"); },
  });
  source.onResponse(page(["a", "b"], { endOfFeed: true }));

  // The items still arrive. This is the property that makes a failed expansion INVISIBLE:
  // the sweep reports a clean success having captured strictly less than it meant to,
  // which is why R7 adds a reported counter rather than changing this behaviour.
  assert.deepEqual(ids(await collect(source.enumerate())), ["a", "b"]);
});

test("an expandItems returning nothing falls back to the page's own items", async () => {
  const source = makeSource({ expandItems: async () => null });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

test("expandItems is NOT called for an empty page — no expansion cost for nothing", async () => {
  let calls = 0;
  const source = makeSource({
    expandItems: async (items) => { calls += 1; return items; },
    maxIdleRounds: 1,
  });
  source.onResponse(page([]));

  await collect(source.enumerate()).catch(() => {});
  assert.equal(calls, 0);
});

// MARK: - the fatal route (098 R10)
//
// `pendingError` carries a fatal page error from the PUSH side to a throw on the PULL
// side, so the engine halts RESUMABLE instead of hammering a flagged account. It has no
// production user today — X's parser never sets `error`, and Instagram (which does) is a
// PULL driver that does not use this seam at all — so rednote's 461 halt will be its
// first execution ever. Untested code on a safety path.

test("a page carrying an error is RE-RAISED from enumerate, not queued", async () => {
  const fatal = Object.assign(new Error("461 risk control"), { challenge: true });
  const source = makeSource();
  source.onResponse(page(["never"], { error: fatal }));

  const thrown = await collect(source.enumerate()).then(() => null, (e) => e);
  assert.equal(thrown, fatal);
});

test("an error arriving DURING the settle is caught by the re-check, not slept past", async () => {
  const fatal = new Error("challenge mid-sweep");
  let scrolls = 0;
  const source = makeSource({
    // The realistic shape: the scroll triggers the request whose response is the
    // challenge. Without the post-settle re-check this would idle into a STALL and be
    // misreported as a wall rather than an account challenge.
    scroll: () => { scrolls += 1; source.onResponse(page([], { error: fatal })); },
  });

  const thrown = await collect(source.enumerate()).then(() => null, (e) => e);
  assert.equal(thrown, fatal);
  assert.equal(scrolls, 1);
});

test("a fatal error PRE-EMPTS pages already queued behind it", async () => {
  const fatal = new Error("challenge");
  const seen = [];
  const source = makeSource();
  source.onResponse(page(["a"]));                      // arrived first, still queued
  source.onResponse(page([], { error: fatal }));
  source.onResponse(page(["b"], { endOfFeed: true }));

  const thrown = await (async () => {
    try {
      for await (const item of source.enumerate()) seen.push(item.sourceId);
      return null;
    } catch (e) { return e; }
  })();
  assert.equal(thrown, fatal);
  // NOT ["a"] — `pendingError` is checked at the TOP of each iteration, so it wins over
  // a non-empty queue and "a" is never yielded. Worth pinning because it is the opposite
  // of the intuitive reading, and because it is the SAFE choice: halting the moment a
  // challenge is seen beats draining a backlog against a flagged account. Nothing is
  // lost — the sweep halts resumable, and a resume re-walks those pages with dedup-skip
  // making the overlap idempotent.
  assert.deepEqual(seen, []);
});

test("an out-of-scope response cannot arm the fatal route", async () => {
  const source = makeSource({
    scope: "mine",
    matchesScope: (url, scope) => url === scope,
  });
  // Another feed's challenge (a replayed buffer entry) must not halt THIS sweep.
  source.onResponse(page([], { error: new Error("someone else's challenge") }), "theirs");
  source.onResponse(page(["a"], { endOfFeed: true }), "mine");

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

// MARK: - the resume cursor (098 R1)

test("enumerate IGNORES the engine's resume cursor — resume is scroll-driven", async () => {
  // Documents the fact behind 098 D1: the engine passes `{ cursor }` and persists one,
  // but an intercept source cannot seek to it (rednote's signatures are per-request and
  // time-bound, so a page cannot be re-requested). Pinning it here so the T1b change that
  // makes the source DECLARE this is a visible edit rather than a silent one.
  const source = makeSource();
  source.onResponse(page(["a"], { endOfFeed: true }));

  const iterator = source.enumerate({ boardId: "99" }, { cursor: "somewhere-in-the-middle" });
  assert.deepEqual(ids(await collect(iterator)), ["a"]);
});

// MARK: - T1b additions

test("the source DECLARES that its resume is scroll-driven (098 R1)", () => {
  // The engine reads this to stop persisting a cursor it can never seek to. A rename
  // here silently restores the misleading checkpoint, so it is asserted, not assumed.
  assert.equal(makeSource().resumable, "scroll");
});

test("onExpandFailure reports a degraded page, and the page still yields (098 R7)", async () => {
  const failures = [];
  const boom = new Error("detail fetch failed");
  const source = makeSource({
    expandItems: async () => { throw boom; },
    onExpandFailure: (error, items) => failures.push({ error, count: items.length }),
  });
  source.onResponse(page(["a", "b"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a", "b"]);
  // Reported, not swallowed — and fail-open is unchanged, which is the whole point.
  assert.deepEqual(failures, [{ error: boom, count: 2 }]);
});

test("onExpandFailure is NOT called when expansion succeeds", async () => {
  let calls = 0;
  const source = makeSource({
    expandItems: async (items) => items,
    onExpandFailure: () => { calls += 1; },
  });
  source.onResponse(page(["a"], { endOfFeed: true }));

  await collect(source.enumerate());
  assert.equal(calls, 0);
});

test("a THROW from onExpandFailure cannot kill the sweep it exists to describe", async () => {
  const source = makeSource({
    expandItems: async () => { throw new Error("expansion failed"); },
    onExpandFailure: () => { throw new Error("and so did the reporter"); },
  });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

// MARK: - T5b: a REFUSED expansion is not a degraded one (098 D8)
//
// Fail-open is right when the expansion merely did not arrive and wrong when the origin
// turned us away: rednote's note-open can come back as the same risk-control refusal the
// board feed can, and degrading past one keeps opening notes against a flagged session.
// The predicate is injected so the seam stays platform-blind — and so X, which supplies
// none, behaves exactly as it did.

test("an expandItems throw the caller calls FATAL is re-raised, not degraded", async () => {
  const refusal = Object.assign(new Error("rednote refused the feed"), { challenge: true });
  const source = makeSource({
    expandItems: async () => { throw refusal; },
    isFatalExpandFailure: (error) => error.challenge === true,
  });
  source.onResponse(page(["a", "b"], { endOfFeed: true }));

  // The page's own items are NOT yielded: the engine halts resumable and a resume re-walks
  // them with dedup-skip, which is the same trade the push-side fatal route makes.
  const seen = [];
  const thrown = await (async () => {
    try {
      for await (const item of source.enumerate()) seen.push(item.sourceId);
      return null;
    } catch (e) { return e; }
  })();
  assert.equal(thrown, refusal);
  assert.deepEqual(seen, []);
});

test("a NON-fatal throw still degrades even when a predicate is supplied", async () => {
  // The predicate must decide per error, not per sweep. A note that would not open is the
  // common case and must never stop a 400-note sweep.
  const failures = [];
  const source = makeSource({
    expandItems: async () => { throw new Error("the note never opened"); },
    isFatalExpandFailure: (error) => error.challenge === true,
    onExpandFailure: (error) => failures.push(error),
  });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
  assert.equal(failures.length, 1);
});

test("with NO predicate, every expansion failure degrades — X's behaviour, unchanged", async () => {
  const source = makeSource({
    expandItems: async () => { throw Object.assign(new Error("refused"), { challenge: true }); },
  });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(ids(await collect(source.enumerate())), ["a"]);
});

test("a fatal expansion failure is NOT reported through onExpandFailure", async () => {
  // `onExpandFailure` describes a sweep that captured less than it meant to. A refusal is
  // not that — it is the sweep stopping — and logging it as a degradation would put a
  // "degraded to the cover" line in front of the halt that actually happened.
  const failures = [];
  const source = makeSource({
    expandItems: async () => { throw Object.assign(new Error("refused"), { challenge: true }); },
    isFatalExpandFailure: () => true,
    onExpandFailure: (error) => failures.push(error),
  });
  source.onResponse(page(["a"], { endOfFeed: true }));

  await collect(source.enumerate()).catch(() => {});
  assert.deepEqual(failures, []);
});

// MARK: - `pages()`, the loop one level down (098 2A, changelog 497)
//
// `enumerate` is `pages` plus X's per-page `expandItems` and the item-level yield. The split
// exists for a consumer that must do its own work BETWEEN a page and the next scroll —
// rednote opens each note while its card is still mounted, which nothing can express through
// `expandItems` because nothing scrolls until `expandItems` has returned.
//
// What these pin is that the two are ONE loop rather than two: the queue, the scroll round,
// the stall and the fatal route are safety decisions, and a second copy of a safety decision
// is the one that quietly stops agreeing with the first.

/** Drain pages into their id arrays. */
const pageIds = async (source) => {
  const out = [];
  for await (const page of source.pages()) out.push(ids(page.items));
  return out;
};

test("pages() hands over whole pages, scrolling for each one exactly as enumerate does", async () => {
  let scrolls = 0;
  const source = makeSource({
    scroll: () => {
      if (scrolls === 0) source.onResponse(page(["c", "d"]));
      if (scrolls === 1) source.onResponse(page(["e"], { endOfFeed: true }));
      scrolls += 1;
    },
  });
  source.onResponse(page(["a", "b"]));

  assert.deepEqual(await pageIds(source), [["a", "b"], ["c", "d"], ["e"]]);
  assert.equal(scrolls, 2, "a page already queued was scrolled for anyway");
});

test("the endOfFeed page is YIELDED before the generator closes, not swallowed by the end", async () => {
  // The order the inline loop had, and the one that matters: rednote expands a page inside
  // the consumer's body, so a last page that closed the generator before its body ran would
  // drop a whole page of notes at the end of every board.
  const seen = [];
  const source = makeSource();
  source.onResponse(page(["a", "b"], { endOfFeed: true }));
  source.onResponse(page(["never"]));

  for await (const p of source.pages()) seen.push(...ids(p.items));
  assert.deepEqual(seen, ["a", "b"], "the last page's items never reached the consumer");
});

test("pages() stalls on a wall with the same typed error the item loop throws", async () => {
  const source = makeSource({ maxIdleRounds: 2 });
  const error = await pageIds(source).then(() => null, (e) => e);
  assert.ok(error instanceof SourceStallError, `expected a stall, got ${error}`);
  assert.equal(error.idleRounds, 2);
});

test("pages() re-raises a fatal page error, and pre-empts the pages queued behind it", async () => {
  const fatal = Object.assign(new Error("461 risk control"), { challenge: true });
  const seen = [];
  const source = makeSource();
  source.onResponse(page(["a"]));
  source.onResponse(page([], { error: fatal }));

  const thrown = await (async () => {
    try {
      for await (const p of source.pages()) seen.push(...ids(p.items));
      return null;
    } catch (e) { return e; }
  })();
  assert.equal(thrown, fatal);
  assert.deepEqual(seen, [], "a challenge is checked at the TOP of the loop — it outranks a full queue");
});

test("pages() does NOT apply expandItems — everything below the page belongs to the caller", async () => {
  // The seam's per-page expansion hook is X's and stays X's. A consumer pulling pages does
  // its own expansion (rednote's is per note and interleaved with scrolling), and having
  // both run would expand every note twice.
  let calls = 0;
  const source = makeSource({ expandItems: async (items) => { calls += 1; return items; } });
  source.onResponse(page(["a"], { endOfFeed: true }));

  assert.deepEqual(await pageIds(source), [["a"]]);
  assert.equal(calls, 0);
});
