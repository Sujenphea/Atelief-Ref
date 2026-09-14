// Atelier Capture — popup view helpers (PURE, unit-tested — decision 9A).
//
// The label/message strings the popup renders, pulled OUT of popup.js's chrome.*/DOM
// glue so they're pinned by `node --test` (popup.js stays thin wiring). Both map a
// resolved sweep spec / a terminal sweep result to the exact copy the toolbar shows —
// the kind of small string logic that silently rots when nothing exercises it.

import { NOTE_OPEN_BUDGET } from "./config.js";

/** The Start-button label for a resolved sweep spec: which feed this sweep targets.
 * X main bookmarks vs. an X bookmark FOLDER vs. a named Pinterest board. */
export function sweepLabel(spec) {
  if (spec.platform === "twitter") {
    return spec.scope.startsWith("bookmarks:")
      ? "Sweep this X bookmark folder"
      : "Sweep your X bookmarks";
  }
  if (spec.platform === "instagram") {
    if (spec.scope && spec.scope.startsWith("saved:collection:")) {
      const slug = spec.input && spec.input.collectionSlug;
      return slug ? `Sweep Instagram collection: ${slug}` : "Sweep this Instagram collection";
    }
    return "Sweep your Instagram saved posts";
  }
  if (spec.platform === "rednote") {
    // No board NAME is available: the board-feed response carries notes and a cursor, not
    // a title, and the popup has only the URL. An id is honest; an invented name is not.
    // What the sweep will CAPTURE is the expansion toggle's business, not the label's —
    // the label would otherwise have to be re-rendered on every tick of a checkbox.
    return "Sweep this rednote board";
  }
  return `Sweep board: ${spec.scope.replace(/^board:/, "")}`;
}

/** The per-note expansion toggle (098 D4 / R13), or null on a platform that has no such
 * pass. Cover-only is the DEFAULT and this is what offers the other mode — so the copy has
 * to carry the cost, not just name the feature: it is one page-open per note, it is the
 * difference between minutes and an hour, and it is a much heavier automation footprint on
 * a site that already fingerprints browsing. The budget is stated as a number because "it
 * stops eventually" is not a thing a user can plan around.
 *
 * `budget` is threaded from config rather than retyped, so the number the popup promises
 * and the number the expander enforces cannot drift. */
export function expansionOption(spec, { budget = NOTE_OPEN_BUDGET } = {}) {
  if (!spec || spec.platform !== "rednote") return null;
  return {
    platform: "rednote",
    label: "Also open each note for its other photos (much slower)",
    detail:
      `Off by default. On, the sweep opens every note on the board — up to ${budget} per `
      + "sweep — so it can save a note's whole photo set instead of just its cover. A large "
      + "board takes tens of minutes rather than a few, and it is a far heavier automation "
      + "footprint. Anything past the budget keeps its cover, and the sweep says so when it "
      + "finishes. Video notes keep their cover too unless you also tick \u201cDownload full "
      + "video\u201d, which opens them for their stream as well.",
  };
}

/** The account-risk warning the popup MUST show — behind an acknowledge gate — before a
 * sweep of `spec` can start, or null when none is needed (002 · B4, mandatory not
 * optional). Instagram's saved-posts sweep carries a real throttle/checkpoint risk to the
 * user's account (the dominant risk the whole feature is designed around); rednote's
 * carries the same risk AND a capability limit worth stating before the user waits out a
 * sweep (098 D8 / R13) — and for rednote the copy depends on `spec.expandNotes`, because the
 * two passes carry materially different footprints. X and Pinterest have no such gate. Pure
 * so popup.js stays chrome/DOM glue. */
export function sweepWarning(spec) {
  if (spec && spec.platform === "rednote") {
    // The gate's copy follows the MODE, because the risk it is gating does: the cover pass
    // is one intercepted response per ~30 notes, expansion is a page-open per note. Asking
    // a user to acknowledge the first and then silently running the second would make the
    // acknowledgement meaningless (098 D8 — the gate is mandatory, not decorative), so
    // popup.js re-renders this and re-arms the checkbox whenever the toggle moves.
    const expanding = spec.expandNotes === true;
    // The VIDEO toggle changes the expansion footprint as much as the expansion toggle
    // changes the cover pass's, and on this platform more: the sampled board is 81 % video,
    // so opening video notes too is several times the note-opens of photos alone. A gate
    // that described the smaller sweep and then ran the larger one would be decorative.
    const video = spec.resolveVideo === true;
    return {
      platform: "rednote",
      text:
        "rednote actively fingerprints browsing (it refused a scripted request with a 461 "
        + "during development) and may throttle or block your account for automated "
        + "browsing. This sweep paces itself gently and pauses if rednote refuses — but "
        + "the risk is real, so sweep at your own risk. "
        + (expanding
          ? "You have asked it to OPEN EVERY NOTE for its other photos: that is one page-open "
            + "per note (hundreds on a large board), far slower, and a much heavier footprint "
            + "than the cover pass. "
            + (video
              ? "Video notes are opened too, for their stream — on a board that is mostly "
                + "video, that is several times as many note-opens as photos alone."
              : "Video notes are not opened at all and still save only their cover.")
          : "It saves ONE cover image per note: a note's other photos and its video are not "
            + "captured."),
    };
  }
  if (spec && spec.platform === "instagram") {
    return {
      platform: "instagram",
      text:
        "Instagram may throttle or checkpoint your account for automated browsing. This "
        + "sweep paces itself gently and pauses if Instagram challenges you — but the "
        + "risk is real, so sweep at your own risk. If Instagram asks you to verify, "
        + "solve it in the tab, then start the sweep again to resume where it paused.",
    };
  }
  return null;
}

/** Whether the Start button should be enabled, given the resolved `spec` and whether the
 * user has ticked the acknowledge box. A platform with no warning is enabled immediately;
 * a warned platform (Instagram) stays disabled until acknowledged. The single rule the
 * popup consults, so the account-risk gate can't be bypassed by a wiring slip. */
export function startEnabled(spec, acknowledged) {
  return sweepWarning(spec) ? !!acknowledged : true;
}

/** Terminal one-liner from the controller's sweep result (best-effort — the popup is
 * usually closed by the time a real sweep finishes; the app's Sweeps tab is truth).
 * `complete` → Done; an explicit Cancel → Stopped; every other halt is resumable. */
export function terminalMessage(result) {
  const n = (result && result.counts && result.counts.ingested) || 0;
  if (result && result.status === "complete") {
    // 098 R7: a PARTIAL expansion is its own outcome. "Done — 412 ingested" is the same
    // sentence whether every note gave up its photos or forty of them quietly kept just a
    // cover, and the whole reason the toggle exists is the difference between those two.
    // Since changelog 495 the shortfall also carries the RATIO, because on a virtualised
    // board the shortfall is most of the board: this is the one line a user reads, so a
    // sweep that expanded 13 of 116 has to say 13 of 116 here or it reads as a success.
    const shortfall = expansionShortfall(result.expansion);
    return shortfall ? `Done, partly expanded — ${n} ingested (${shortfall}).` : `Done — ${n} ingested.`;
  }
  if (result && result.haltStatus === "halted") return `Stopped — ${n} ingested.`;
  const why = haltReason(result);
  return why ? `Paused (resumable) — ${n} ingested. ${why}` : `Paused (resumable) — ${n} ingested.`;
}

/** WHY a sweep halted, as the sentence to show the user — or null when it halted without
 * an enumeration error (an app Pause, a media auth wall).
 *
 * This is the only place a runtime halt's reason reaches a human. `REASON_MESSAGE` cannot
 * serve it: that table answers `resolveSweepSpec`, which refuses BEFORE a sweep starts and
 * knows only the tab's URL — and the halts worth explaining (a board swept from the middle,
 * a 461 refusal, a scroll wall) are all things only the running sweep can discover. So the
 * error carries its own copy and this renders it; the alternative is a second table of
 * strings keyed by error name, which could only ever drift from the errors it describes.
 *
 * The engine stringifies the error (`String(error)` → `"RednoteFeedStartError: Reload…"`),
 * so the class name is trimmed off the front: it is a fact about our source tree, not
 * something to show a user mid-sentence. Anything that does not carry that prefix is
 * passed through as-is. */
export function haltReason(result) {
  const raw = result && typeof result.error === "string" ? result.error.trim() : "";
  if (!raw) return null;
  return raw.replace(/^[A-Za-z]*Error:\s*/, "") || null;
}

/** How an expansion pass fell short, phrased for the status line, or null when it did not.
 * Kept apart from `terminalMessage` so the reasons a sweep can be partial are each named
 * rather than collapsed into "partial" — they ask the user for different things, and one of
 * them asks for nothing they can do.
 *
 * COVERAGE COMES FIRST, because without it none of the reasons can be read. "4 kept covers
 * only" is the same sentence whether the sweep expanded four hundred notes or none, and on
 * a virtualised board it is the second: a live board was measured mounting 13 note cards at
 * a time against a feed page of 37-38 and a board of 116, so a sweep that looks like it
 * worked reached a tenth of it (changelog 495). `expanded N of M` is what makes that
 * visible without arithmetic, and it is stated whenever the sweep attempted anything at
 * all — a sweep that attempted nothing says nothing, rather than "0 of 0".
 *
 * The four reasons, in the order a reader needs them:
 *   · `unreachable` — the note's card was never on the page, so it could not be OPENED.
 *     The user can do nothing about it and re-sweeping will not help; it is the grid's
 *     virtualisation, and 098 2A is the fix.
 *   · `degraded`    — the note WAS opened and did not give up its photos (a timeout, an
 *     unparsable body). Reached, no answer.
 *   · `detailRefused` — the note was opened and rednote REFUSED it (changelog 500). Named
 *     apart from `degraded` because it asks for something different: the images are
 *     probably still there, so sweeping again is worth doing, where re-sweeping a note
 *     that timed out mostly is not.
 *   · `budgetExhausted` — the other one with an action attached: sweep again. */
export function expansionShortfall(expansion) {
  if (!expansion || !expansion.partial) return null;
  const parts = [];
  if (expansion.attempted > 0) parts.push(`expanded ${expansion.expanded || 0} of ${expansion.attempted}`);
  if (expansion.unreachable > 0) {
    parts.push(`${expansion.unreachable} had no card on the page to open `
      + "\u2014 the board only renders what is on screen");
  }
  if (expansion.degraded > 0) parts.push(`${expansion.degraded} kept covers only`);
  if (expansion.detailRefused > 0) {
    parts.push(`rednote refused ${expansion.detailRefused} when opened — sweep again`);
  }
  if (expansion.budgetExhausted) parts.push(`the ${expansion.budget}-note budget ran out — sweep again for the rest`);
  return parts.join("; ") || "some notes kept covers only";
}

/** Map a dispatch reply to the popup's terminal UI state: `{ status, enableStart }`.
 * A success shows the terminal message and leaves Start disabled (the sweep ran). ANY
 * failure — a RESOLVED `{ ok: false }` OR a thrown rejection (normalise it to this
 * shape) — re-enables Start so the user can retry (7A: the old code re-enabled only on a
 * rejection, so a resolved failure left Start dead with no way to relaunch). */
export function launchOutcome(reply) {
  if (reply && reply.ok) return { status: terminalMessage(reply.result), enableStart: false };
  return { status: `Error: ${(reply && reply.error) || "unknown"}`, enableStart: true };
}
