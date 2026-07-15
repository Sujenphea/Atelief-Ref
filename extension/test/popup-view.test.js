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
} from "../src/popup-view.js";

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
