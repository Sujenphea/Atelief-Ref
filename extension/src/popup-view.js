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

/** The account-risk warning the popup MUST show — behind an acknowledge gate — before a
 * sweep of `spec` can start, or null when none is needed (002 · B4, mandatory not
 * optional). Instagram's saved-posts sweep carries a real throttle/checkpoint risk to the
 * user's account (the dominant risk the whole feature is designed around); X and
 * Pinterest have no such gate. Pure so popup.js stays chrome/DOM glue. */
export function sweepWarning(spec) {
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
