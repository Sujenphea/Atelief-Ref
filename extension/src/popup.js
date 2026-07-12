// Atelier Capture — toolbar popup: resolve the active tab, launch a sweep.
//
// Thin chrome.* glue around two PURE units: `resolveSweepSpec` (tab → spec | reason,
// tested in bulk-context.test.js) and `dispatchStart` (send + cold-tab recovery,
// tested in bulk-dispatch.test.js). This file only wires the real chrome fns and
// renders — no sweep logic lives here.
//
// Flow: on open, executeScript reads {url, collageHref} from the tab's DOM (ISOLATED
// world — the board id is the "Collage" button's href), resolve, enable/disable Start.
// On click, dispatch the START message (delegating progress to the app's Sweeps tab).

import { resolveSweepSpec, REASON_MESSAGE } from "./bulk-context.js";
import { dispatchStart } from "./bulk-dispatch.js";
import { sweepLabel, launchOutcome } from "./popup-view.js";

const els = {
  target: document.getElementById("target"),
  reason: document.getElementById("reason"),
  videoRow: document.getElementById("videoRow"),
  resolveVideo: document.getElementById("resolveVideo"),
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
}

function showTarget(spec) {
  els.target.textContent = sweepLabel(spec);
  els.reason.hidden = true;
  els.videoRow.hidden = false;
  els.start.disabled = false;
}

async function getActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
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
    spec: { ...spec, resolveVideo: els.resolveVideo.checked },
    sendMessage: (message) => chrome.tabs.sendMessage(tabId, message),
    injectScript: () => chrome.scripting.executeScript({ target: { tabId }, files: ["src/bulk-loader.js"] }),
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
    const [injection] = await chrome.scripting.executeScript({
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
