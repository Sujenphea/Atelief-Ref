// Atelier Capture — popup view-helper tests (decision 9A).
//
// The label + terminal-message strings the toolbar renders are pure functions now, so
// they're pinned here instead of only living inside chrome.*/DOM glue popup.js can't
// unit-test. Covers every branch of each: X main / X folder / Pinterest board labels,
// and the complete / cancelled / paused / empty-result message arms.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  sweepLabel, sweepWarning, startEnabled, terminalMessage, launchOutcome,
  expansionOption, expansionShortfall, haltReason, APP_PAUSE_MESSAGE,
} from "../src/popup-view.js";
import { RednoteFeedStartError, RednoteStallError } from "../src/rednote-source.js";
import { NOTE_OPEN_BUDGET } from "../src/config.js";

test("sweepLabel: X main bookmarks vs. a folder vs. a Pinterest board vs. IG saved", () => {
  assert.equal(
    sweepLabel({ platform: "twitter", scope: "bookmarks" }),
    "Sweep your X bookmarks");
  assert.equal(
    sweepLabel({ platform: "twitter", scope: "bookmarks:2005398616131952777" }),
    "Sweep this X bookmark folder");
  assert.equal(
    sweepLabel({ platform: "pinterest", scope: "board:cool-refs" }),
    "Sweep board: cool-refs");
  assert.equal(
    sweepLabel({ platform: "instagram", scope: "saved" }),
    "Sweep your Instagram saved posts");
  // A collection sweep names the collection by its slug (falls back if the slug is absent).
  assert.equal(
    sweepLabel({ platform: "instagram", scope: "saved:collection:1021461010622913",
      input: { collectionId: "1021461010622913", collectionSlug: "test2" } }),
    "Sweep Instagram collection: test2");
  assert.equal(
    sweepLabel({ platform: "instagram", scope: "saved:collection:42", input: {} }),
    "Sweep this Instagram collection");
});

test("sweepWarning + startEnabled: a collection sweep carries the SAME account-risk gate", () => {
  // A collection replays the same synthetic endpoint, so the warning + acknowledge gate
  // must apply exactly as for the flat saved feed — not be bypassed by the different scope.
  const collSpec = { platform: "instagram", scope: "saved:collection:42", input: {} };
  assert.ok(sweepWarning(collSpec));
  assert.equal(startEnabled(collSpec, false), false);
  assert.equal(startEnabled(collSpec, true), true);
});

test("sweepWarning: Instagram carries an account-risk warning; X/Pinterest carry none", () => {
  const warn = sweepWarning({ platform: "instagram", scope: "saved" });
  assert.equal(warn.platform, "instagram");
  assert.match(warn.text, /throttle|checkpoint/i);          // names the real risk
  assert.equal(sweepWarning({ platform: "twitter", scope: "bookmarks" }), null);
  assert.equal(sweepWarning({ platform: "pinterest", scope: "board:x" }), null);
});

test("startEnabled: IG requires acknowledgement; unwarned platforms enable immediately", () => {
  // The account-risk gate: IG Start stays disabled until the box is ticked.
  assert.equal(startEnabled({ platform: "instagram", scope: "saved" }, false), false);
  assert.equal(startEnabled({ platform: "instagram", scope: "saved" }, true), true);
  // No warning → no gate, enabled regardless of the (absent) checkbox.
  assert.equal(startEnabled({ platform: "twitter", scope: "bookmarks" }, false), true);
  assert.equal(startEnabled({ platform: "pinterest", scope: "board:x" }, false), true);
});

test("terminalMessage: complete → Done, with the ingested count", () => {
  assert.equal(
    terminalMessage({ status: "complete", counts: { ingested: 42 } }),
    "Done — 42 ingested.");
});

test("terminalMessage: an explicit Cancel → Stopped", () => {
  assert.equal(
    terminalMessage({ status: "halted", haltStatus: "halted", counts: { ingested: 3 } }),
    "Stopped — 3 ingested.");
});

test("terminalMessage: a resumable halt (pause / wall) → Paused", () => {
  assert.equal(
    terminalMessage({ status: "halted", haltStatus: "paused", counts: { ingested: 7 } }),
    `Paused (resumable) — 7 ingested. ${APP_PAUSE_MESSAGE}`);
  // A self-halt carries no app intent, so it gets the bare line — there is no pause to
  // attribute and claiming one would be a lie about who stopped the sweep.
  assert.equal(
    terminalMessage({ status: "halted", haltStatus: null, counts: { ingested: 0 } }),
    "Paused (resumable) — 0 ingested.");
});

test("terminalMessage: an APP pause says who paused it and how to pick it up again", () => {
  // The halt this was live-observed on (508): counts fine, nothing failed, no error string
  // at all — the app had flipped the job to `paused` underneath a healthy sweep, and the
  // only way to learn that was to read the engine's source.
  const paused = terminalMessage({
    status: "halted", haltStatus: "paused", counts: { ingested: 2 }, error: null,
  });
  assert.match(paused, /^Paused \(resumable\) — 2 ingested\./, "the outcome line still leads");
  assert.ok(paused.endsWith(APP_PAUSE_MESSAGE), "the pause reached the user unexplained");

  // The copy's two load-bearing properties, asserted on the constant itself so rewording it
  // stays free and hollowing it out does not.
  assert.match(APP_PAUSE_MESSAGE, /\bapp\b/i, "it must name WHO paused the sweep");
  // The action is Start, not the app's Resume button: `resumeSweep` only writes `status`, and
  // `openOrReopen` reopens the paused job from the checkpoint anyway.
  assert.match(APP_PAUSE_MESSAGE, /start the sweep again/i,
    "a halt with no action in it is still a mystery (see RednoteFeedStartError)");
  // It must NOT guess which pause: a Pause in the Sweeps tab and the app's staleness
  // reconciler arrive identically, and the extension cannot tell them apart.
  assert.equal(/\bstale|\btimed out|\byou paused|\bidle\b/i.test(APP_PAUSE_MESSAGE), false,
    "the extension cannot know which pause this was, so it must not claim one");
});

test("terminalMessage: an explicit reason outranks the app-pause line", () => {
  // Both facts are true of this result; the error is the more specific one, and appending
  // both would make the user read a generic pause line to reach the refusal that matters.
  const refused = terminalMessage({
    status: "halted", haltStatus: "paused", counts: { ingested: 0 },
    error: String(new RednoteFeedStartError()),
  });
  assert.match(refused, /reload the board page/i);
  assert.equal(refused.includes(APP_PAUSE_MESSAGE), false,
    "the specific refusal was buried under the generic pause line");
});

test("terminalMessage: a resumable halt SAYS WHY, so a refusal is actionable and not a mystery", () => {
  // The only place a RUNTIME halt reaches a human. `REASON_MESSAGE` cannot serve this one:
  // that table answers `resolveSweepSpec`, which refuses before a sweep starts from the
  // tab URL alone — and "this board was already scrolled past its first page" is something
  // only the running sweep can discover. Constructing the real error (rather than pasting
  // its text) is what makes this test fail if the copy ever stops telling the user what to do.
  const refused = terminalMessage({
    status: "halted", haltStatus: null, counts: { ingested: 0 },
    error: String(new RednoteFeedStartError()),
  });
  assert.match(refused, /Paused \(resumable\) — 0 ingested\./, "the outcome line still leads");
  assert.match(refused, /reload the board page/i, "the halt reached the user without its instruction");
  assert.equal(refused.includes("RednoteFeedStartError"), false,
    "the class name is a fact about our source tree, not copy for a user");

  // The same route carries the other runtime halts — a stall says which wall it hit.
  const stalled = terminalMessage({
    status: "halted", haltStatus: null, counts: { ingested: 78 },
    error: String(new RednoteStallError(4)),
  });
  assert.match(stalled, /78 ingested/);
  assert.match(stalled, /stalled/);
  assert.equal(stalled.includes("RednoteStallError"), false);
});

test("terminalMessage: a halt with nothing to explain reads exactly as it always did", () => {
  // A media auth wall carries no enumeration error and no app intent; appending an empty
  // reason (or the word "null") would be worse than saying nothing.
  assert.equal(
    terminalMessage({ status: "halted", haltStatus: null, counts: { ingested: 7 }, error: null }),
    "Paused (resumable) — 7 ingested.");
  // A Cancel is terminal, not a wall — its line is about the user's own decision, so it is
  // untouched by 508 even though the app set that status too.
  const cancelled = terminalMessage({
    status: "halted", haltStatus: "halted", counts: { ingested: 3 },
    error: String(new RednoteFeedStartError()),
  });
  assert.equal(cancelled, "Stopped — 3 ingested.");
});

test("haltReason: the class-name prefix is trimmed, anything else is passed through whole", () => {
  assert.equal(haltReason(null), null);
  assert.equal(haltReason({ status: "halted" }), null);
  assert.equal(haltReason({ error: "   " }), null, "whitespace is not a reason");
  assert.equal(haltReason({ error: "the tab went away" }), "the tab went away");
  assert.equal(haltReason({ error: "Error: plain" }), "plain");
  // Only the leading class name goes: a colon inside the sentence is part of the sentence.
  assert.equal(haltReason({ error: "TypeError: a: b" }), "a: b");
});

test("terminalMessage: a missing/garbage result defaults to 0 and doesn't throw", () => {
  assert.equal(terminalMessage(null), "Paused (resumable) — 0 ingested.");
  assert.equal(terminalMessage({}), "Paused (resumable) — 0 ingested.");
});

test("launchOutcome: a success shows the terminal line and leaves Start disabled", () => {
  const out = launchOutcome({ ok: true, result: { status: "complete", counts: { ingested: 5 } } });
  assert.deepEqual(out, { status: "Done — 5 ingested.", enableStart: false });
});

test("launchOutcome: a RESOLVED {ok:false} re-enables Start so the user can retry (7A)", () => {
  // This is the load-bearing fix: previously only a thrown rejection re-enabled Start, so
  // a resolved failure (e.g. sweep-already-running) left the button dead.
  const out = launchOutcome({ ok: false, error: "sweep-already-running" });
  assert.deepEqual(out, { status: "Error: sweep-already-running", enableStart: true });
});

test("launchOutcome: a garbage/absent reply is treated as a failure (Start re-enabled)", () => {
  assert.deepEqual(launchOutcome(undefined), { status: "Error: unknown", enableStart: true });
  assert.deepEqual(launchOutcome({ ok: false }), { status: "Error: unknown", enableStart: true });
});

// MARK: - the rednote expansion toggle (098 R13 / T5b)

test("expansionOption: offered on rednote, nowhere else", () => {
  // A toggle on a platform with no expansion pass would be a checkbox that does nothing.
  const option = expansionOption({ platform: "rednote", scope: "board:abc" });
  assert.equal(option.platform, "rednote");
  assert.ok(option.label.length > 0);
  for (const platform of ["twitter", "instagram", "pinterest"]) {
    assert.equal(expansionOption({ platform, scope: "x" }), null);
  }
  assert.equal(expansionOption(null), null);
});

test("expansionOption: the copy states the COST, and states the budget as a number", () => {
  // The whole reason cover-only is the default is the cost table (098 §Cost budget). A
  // label that only named the feature would sell the slow mode without pricing it.
  const option = expansionOption({ platform: "rednote", scope: "board:abc" });
  assert.match(option.label, /slower/i, "the label warns before the box is ticked");
  assert.match(option.detail, /off by default/i);
  assert.match(option.detail, new RegExp(String(NOTE_OPEN_BUDGET)), "the enforced ceiling is promised");
  assert.match(option.detail, /video/i, "video notes keeping their cover is a stated limit");
});

test("expansionOption: the promised budget IS the enforced one", () => {
  // Threaded from config rather than retyped: a popup that promised 400 while the expander
  // stopped at 50 would be a lie with no test between it and the user.
  const option = expansionOption({ platform: "rednote", scope: "board:abc" }, { budget: 7 });
  assert.match(option.detail, /up to 7 per/);
});

test("sweepWarning: rednote's gate describes the MODE the user actually chose", () => {
  // D8's gate is mandatory, not decorative. Acknowledging "one cover per note" and then
  // running a page-open per note would make the acknowledgement meaningless.
  const cover = sweepWarning({ platform: "rednote", scope: "board:abc" });
  const expanded = sweepWarning({ platform: "rednote", scope: "board:abc", expandNotes: true });

  for (const warning of [cover, expanded]) {
    assert.equal(warning.platform, "rednote");
    assert.match(warning.text, /461|throttle|block/i, "the account risk is named in both modes");
  }
  assert.match(cover.text, /ONE cover image per note/);
  assert.match(expanded.text, /OPEN EVERY NOTE/);
  assert.notEqual(cover.text, expanded.text, "the gate said the same thing about two different sweeps");
});

test("sweepWarning: the gate also follows the VIDEO toggle, which is what opens video notes", () => {
  // 098 T6c: on a board that is 81 % video, ticking "Download full video" alongside
  // expansion multiplies the note-opens several times over. D8's gate is mandatory rather
  // than decorative, so acknowledging the smaller sweep must not silently authorise this one.
  const base = { platform: "rednote", scope: "board:abc", expandNotes: true };
  const photos = sweepWarning(base);
  const withVideo = sweepWarning({ ...base, resolveVideo: true });

  assert.notEqual(photos.text, withVideo.text, "the gate said the same thing about two different sweeps");
  assert.match(photos.text, /not opened at all/i);
  assert.match(withVideo.text, /opened too/i);
  // The cover pass is unaffected by the video box — it never fetches a note detail, so no
  // ladder is ever seen and no note is ever opened.
  assert.equal(
    sweepWarning({ platform: "rednote", scope: "board:abc" }).text,
    sweepWarning({ platform: "rednote", scope: "board:abc", resolveVideo: true }).text);
});

test("expansionOption: the copy says video notes need the OTHER toggle too", () => {
  // The one thing a user cannot discover from the expansion label alone: expansion opens
  // notes, the video toggle decides whether a VIDEO note is one of them.
  const option = expansionOption({ platform: "rednote", scope: "board:abc" });
  assert.match(option.detail, /video notes keep their cover too unless/i);
});

test("startEnabled: rednote stays gated in BOTH modes", () => {
  for (const spec of [
    { platform: "rednote", scope: "board:abc" },
    { platform: "rednote", scope: "board:abc", expandNotes: true },
  ]) {
    assert.equal(startEnabled(spec, false), false);
    assert.equal(startEnabled(spec, true), true);
  }
});

test("sweepLabel: rednote names the platform without promising a mode", () => {
  // The label is rendered once, before the toggle exists; a mode in it would go stale the
  // moment the box is ticked.
  const label = sweepLabel({ platform: "rednote", scope: "board:abc", input: { boardId: "abc" } });
  assert.match(label, /rednote/i);
  assert.doesNotMatch(label, /covers only/i);
});

// MARK: - `partial` as a first-class terminal outcome (098 R7)

test("terminalMessage: a partial expansion reads differently from a complete one", () => {
  // The thing R7 asks for, at the only place a user sees it. Before this, a sweep where
  // forty notes quietly kept their cover produced the identical sentence to one where every
  // note gave up its photos.
  const full = terminalMessage({
    status: "complete", counts: { ingested: 90 },
    expansion: { expanded: 10, degraded: 0, budgetExhausted: false, partial: false },
  });
  const partial = terminalMessage({
    status: "complete", counts: { ingested: 90 },
    expansion: { expanded: 6, degraded: 4, budgetExhausted: false, budget: 400, partial: true },
  });

  assert.equal(full, "Done — 90 ingested.");
  assert.notEqual(partial, full);
  assert.match(partial, /partly expanded/);
  assert.match(partial, /4 kept covers only/);
});

test("terminalMessage: a cover-only sweep is not reported as partial", () => {
  assert.equal(
    terminalMessage({ status: "complete", counts: { ingested: 37 }, expansion: null }),
    "Done — 37 ingested.");
});

// MARK: - coverage, on a virtualised board (changelog 495)

test("terminalMessage: a sweep that reached a tenth of the board says WHICH tenth", () => {
  // The measured live case: the grid mounts ~13 note cards at a time, a feed page carries
  // 37-38 notes, the board holds 116 — so expansion reaches a fraction of it and the rest
  // have no card to click. Without the ratio this is "Done, partly expanded — 77 ingested
  // (103 kept covers only)": true, and it still leaves the user to work out that the sweep
  // got a ninth of what the toggle promised.
  const line = terminalMessage({
    status: "complete",
    counts: { ingested: 77 },
    expansion: {
      mode: "expansion", budget: 400, attempted: 116, expanded: 13, unreachable: 103,
      degraded: 0, budgetExhausted: false, partial: true,
    },
  });

  assert.match(line, /partly expanded/);
  assert.match(line, /13 of 116/, "the coverage is stated, not left as arithmetic");
  assert.match(line, /103/, "and so is the size of what it could not reach");
  // A note that was never opened did not "keep its cover" in the sense that phrase carries
  // — that one is for a note the sweep reached and that gave nothing back.
  assert.doesNotMatch(line, /kept covers only/);
});

test("expansionShortfall: 'could not reach it' and 'reached it, no answer' stay separate", () => {
  const both = expansionShortfall({
    partial: true, attempted: 10, expanded: 4, unreachable: 5, degraded: 1, budgetExhausted: false,
  });
  assert.match(both, /expanded 4 of 10/);
  assert.match(both, /5 had no card/, "could not reach it");
  assert.match(both, /only renders what is on screen/, "…and why, since the user can do nothing about it");
  assert.match(both, /1 kept covers only/, "reached it, no answer");
});

test("expansionShortfall: a sweep that attempted nothing states no ratio", () => {
  // Expansion on and nothing ever opened — an empty board, or a sweep refused before it
  // held a page. "expanded 0 of 0" is a sentence about nothing; whatever else is true still
  // has to read.
  const line = expansionShortfall({
    partial: true, attempted: 0, expanded: 0, unreachable: 0, degraded: 0,
    budgetExhausted: true, budget: 400,
  });
  assert.doesNotMatch(line, /of 0/);
  assert.match(line, /400-note budget ran out/);
});

test("expansionShortfall: an exhausted budget beside heavy unreachability keeps both", () => {
  // They co-occur on any board bigger than the budget, and they ask for different things:
  // one is fixed by sweeping again, the other is not fixed by anything the user can do.
  const line = expansionShortfall({
    partial: true, attempted: 400, expanded: 40, unreachable: 360, degraded: 0,
    budgetExhausted: true, budget: 400,
  });
  assert.match(line, /expanded 40 of 400/);
  assert.match(line, /360 had no card/);
  assert.match(line, /sweep again/);
});

test("expansionShortfall: a REFUSED note is named apart from one that merely gave no answer", () => {
  // They read the same to a user who is only told "kept covers only", and they ask for
  // opposite things. A note that timed out will probably time out again; a note rednote
  // REFUSED (changelog 500 — 020's `xsec_token` hazard) very likely still has its images,
  // and the credential that fetches them is minted fresh by the next sweep. So the refusal
  // gets the action and the degradation does not.
  const line = expansionShortfall({
    partial: true, attempted: 10, expanded: 7, unreachable: 0, degraded: 1, detailRefused: 2,
    budgetExhausted: false,
  });
  assert.match(line, /expanded 7 of 10/);
  assert.match(line, /1 kept covers only/);
  assert.match(line, /refused 2 when opened — sweep again/);

  // …and a sweep with none of them says nothing about refusals.
  const clean = expansionShortfall({
    partial: true, attempted: 10, expanded: 9, degraded: 1, detailRefused: 0, budgetExhausted: false,
  });
  assert.doesNotMatch(clean, /refused/);
});

test("expansionShortfall: a sweep whose ONLY shortfall is refusals still says so", () => {
  // The regression this guards: `partial` gained `detailRefused` in changelog 500, so a
  // board where every opened note was refused and nothing else went wrong is partial — and
  // a shortfall line that had no branch for it would render the bare fallback and lose the
  // one fact the user needs.
  const line = expansionShortfall({
    partial: true, attempted: 5, expanded: 0, unreachable: 0, degraded: 0, detailRefused: 5,
    budgetExhausted: false,
  });
  assert.match(line, /expanded 0 of 5/);
  assert.match(line, /refused 5 when opened — sweep again/);
});

test("expansionShortfall: names the two reasons apart, because only one is actionable", () => {
  // "Sweep again" fixes an exhausted budget and does nothing for a note that would not open.
  assert.equal(expansionShortfall(null), null);
  assert.equal(expansionShortfall({ partial: false, degraded: 0 }), null);
  assert.match(
    expansionShortfall({ partial: true, degraded: 0, budgetExhausted: true, budget: 400 }),
    /400-note budget ran out — sweep again/);
  assert.match(expansionShortfall({ partial: true, degraded: 3, budgetExhausted: false }), /3 kept covers only/);
  const both = expansionShortfall({ partial: true, degraded: 3, budgetExhausted: true, budget: 400 });
  assert.match(both, /3 kept covers only/);
  assert.match(both, /budget ran out/);
});
