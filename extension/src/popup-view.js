// Atelier Capture — popup view helpers (PURE, unit-tested — decision 9A).
//
// The label/message strings the popup renders, pulled OUT of popup.js's chrome.*/DOM
// glue so they're pinned by `node --test` (popup.js stays thin wiring). Both map a
// resolved sweep spec / a terminal sweep result to the exact copy the toolbar shows —
// the kind of small string logic that silently rots when nothing exercises it.

/** The Start-button label for a resolved sweep spec: which feed this sweep targets.
 * X main bookmarks vs. an X bookmark FOLDER vs. a named Pinterest board. */
export function sweepLabel(spec) {
  if (spec.platform === "twitter") {
    return spec.scope.startsWith("bookmarks:")
      ? "Sweep this X bookmark folder"
      : "Sweep your X bookmarks";
  }
  if (spec.platform === "instagram") return "Sweep your Instagram saved posts";
  return `Sweep board: ${spec.scope.replace(/^board:/, "")}`;
}

/** Terminal one-liner from the controller's sweep result (best-effort — the popup is
 * usually closed by the time a real sweep finishes; the app's Sweeps tab is truth).
 * `complete` → Done; an explicit Cancel → Stopped; every other halt is resumable. */
export function terminalMessage(result) {
  const n = (result && result.counts && result.counts.ingested) || 0;
  if (result && result.status === "complete") return `Done — ${n} ingested.`;
  if (result && result.haltStatus === "halted") return `Stopped — ${n} ingested.`;
  return `Paused (resumable) — ${n} ingested.`;
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
