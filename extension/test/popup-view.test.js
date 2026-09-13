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
  expansionOption, expansionShortfall,
} from "../src/popup-view.js";
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
    "Paused (resumable) — 7 ingested.");
  assert.equal(
    terminalMessage({ status: "halted", haltStatus: null, counts: { ingested: 0 } }),
    "Paused (resumable) — 0 ingested.");
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
