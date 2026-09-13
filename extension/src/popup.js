// Atelier Capture — toolbar popup: resolve the active tab, launch a sweep.
//
// Thin browser-API glue around two PURE units: `resolveSweepSpec` (tab → spec | reason,
// tested in bulk-context.test.js) and `dispatchStart` (send + cold-tab recovery,
// tested in bulk-dispatch.test.js). This file only wires the real tabs/scripting fns —
// through `browser.js`, never `chrome` directly — and renders; no sweep logic here.
//
// Flow: on open, executeScript reads {url, collageHref} from the tab's DOM (ISOLATED
// world — the board id is the "Collage" button's href), resolve, enable/disable Start.
// On click, dispatch the START message (delegating progress to the app's Sweeps tab).

import { resolveSweepSpec, REASON_MESSAGE } from "./bulk-context.js";
import { dispatchStart } from "./bulk-dispatch.js";
import {
  sweepLabel, sweepWarning, startEnabled, launchOutcome, expansionOption,
} from "./popup-view.js";
import { browser } from "./browser.js";

const els = {
  target: document.getElementById("target"),
  reason: document.getElementById("reason"),
  warn: document.getElementById("warn"),
  ackRow: document.getElementById("ackRow"),
  acknowledge: document.getElementById("acknowledge"),
  videoRow: document.getElementById("videoRow"),
  resolveVideo: document.getElementById("resolveVideo"),
  expandRow: document.getElementById("expandRow"),
  expandNotes: document.getElementById("expandNotes"),
  expandLabel: document.getElementById("expandLabel"),
  expandDetail: document.getElementById("expandDetail"),
  start: document.getElementById("start"),
  status: document.getElementById("status"),
};

/** Runs IN the tab (ISOLATED world). Returns the page URL + the "Collage" button's
 * href (Pinterest board pages carry the board id there:
 * `/collage-creation-tool/?boardId=<digits>`). Self-contained — executeScript
 * serializes it, so it can't close over anything here. */
function readPageContext() {
  const collage = document.querySelector('a[href*="/collage-creation-tool/"][href*="boardId="]');
  return { url: location.href, collageHref: collage ? collage.getAttribute("href") : null };
}

function showReason(reason) {
  els.target.hidden = true;
  els.reason.hidden = false;
  els.reason.textContent = REASON_MESSAGE[reason] || REASON_MESSAGE["not-supported-site"];
  els.start.disabled = true;
  els.videoRow.hidden = true;
  els.expandRow.hidden = true;
  els.expandDetail.hidden = true;
  els.warn.hidden = true;
  els.ackRow.hidden = true;
}

/** The spec as the user has currently configured it — the resolved spec plus the toggles.
 * BOTH toggles are folded in HERE as well as at launch because the risk gate's copy depends
 * on them (098 D8): the acknowledgement has to describe the sweep that will run, and on
 * rednote the video toggle decides whether the 81 % of notes that are video get opened. */
function configuredSpec(spec) {
  return {
    ...spec,
    expandNotes: !!(els.expandNotes && els.expandNotes.checked),
    resolveVideo: !!(els.resolveVideo && els.resolveVideo.checked),
  };
}

/** Render (or re-render) the account-risk gate for the currently configured sweep.
 * Ticking the expansion box escalates the footprint from one intercepted response per ~30
 * notes to a page-open per note, so the acknowledgement is RESET and Start re-disabled —
 * an acknowledgement of the cover pass is not an acknowledgement of this one. Ticking the
 * VIDEO box escalates it again on rednote (it is what opens the video notes), so it
 * re-renders through here too. */
function showWarning(spec) {
  const warning = sweepWarning(configuredSpec(spec));
  if (warning) {
    els.warn.hidden = false;
    els.warn.textContent = warning.text;
    els.ackRow.hidden = false;
    els.acknowledge.checked = false;
  } else {
    els.warn.hidden = true;
    els.ackRow.hidden = true;
  }
  els.start.disabled = !startEnabled(configuredSpec(spec), els.acknowledge.checked);
}

function showTarget(spec) {
  els.target.textContent = sweepLabel(spec);
  els.reason.hidden = true;
  els.videoRow.hidden = false;
  els.resolveVideo.addEventListener("change", () => showWarning(spec));

  // The per-note expansion toggle (098 R13) — rednote only, OFF by default, with its cost
  // spelled out beside it rather than discovered after a 40-minute sweep.
  const expansion = expansionOption(spec);
  if (expansion) {
    els.expandRow.hidden = false;
    els.expandLabel.textContent = expansion.label;
    els.expandDetail.hidden = false;
    els.expandDetail.textContent = expansion.detail;
    els.expandNotes.checked = false;
    els.expandNotes.addEventListener("change", () => showWarning(spec));
  } else {
    els.expandRow.hidden = true;
    els.expandDetail.hidden = true;
  }

  // Account-risk gate (002 · B4): a warned platform (Instagram, rednote) shows the warning
  // + an acknowledge checkbox and keeps Start disabled until it's ticked; an unwarned
  // platform enables Start immediately. `startEnabled` is the single source of truth so the
  // gate can't be bypassed by a wiring slip.
  els.acknowledge.addEventListener("change", () => {
    els.start.disabled = !startEnabled(configuredSpec(spec), els.acknowledge.checked);
  });
  showWarning(spec);
}

async function getActiveTab() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  return tab && tab.id != null ? tab : null;
}

/** Render a terminal launch outcome: set the status line, and re-enable Start iff the
 * outcome says to (a failure — so the user can retry). */
function applyOutcome({ status, enableStart }) {
  els.status.textContent = status;
  if (enableStart) els.start.disabled = false;
}

function launch(tabId, spec) {
  els.start.disabled = true;
  // Delegate progress to the app (4A): announce it's running right away — the sweep
  // lives in the content script and survives this popup closing. The .then/.catch
  // overwrite with a terminal/error line only if the popup is still open.
  els.status.textContent = "Sweeping… watch the app's Sweeps tab. Safe to close this popup.";
  dispatchStart({
    spec: configuredSpec(spec),   // both toggles — the SAME spec the gate described
    sendMessage: (message) => browser.tabs.sendMessage(tabId, message),
    injectScript: () => browser.scripting.executeScript({ target: { tabId }, files: ["src/bulk-loader.js"] }),
  })
    // A resolved {ok:false} is as terminal as a rejection — both re-enable Start (7A).
    .then((reply) => applyOutcome(launchOutcome(reply)))
    .catch((error) => applyOutcome(launchOutcome({ ok: false, error: error.message || String(error) })));
}

async function init() {
  const tab = await getActiveTab();
  if (!tab) { showReason("not-supported-site"); return; }

  let context;
  try {
    const [injection] = await browser.scripting.executeScript({
      target: { tabId: tab.id }, func: readPageContext,
    });
    context = injection.result;
  } catch {
    showReason("not-supported-site"); // chrome:// / web store / otherwise unscriptable
    return;
  }

  const resolution = resolveSweepSpec(context);
  if (!resolution.ok) { showReason(resolution.reason); return; }

  showTarget(resolution.spec);
  els.start.addEventListener("click", () => launch(tab.id, resolution.spec));
}

init();
