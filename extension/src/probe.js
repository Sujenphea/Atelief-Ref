// Atelier Capture — the tier-3 probe popup (096 § T0).
//
// A MEASUREMENT INSTRUMENT, not a shipping surface. It exists to answer 096 § T0's
// questions on a real phone and to write the fixture corpus 096 § T3 then tests against.
// When T0 is answered, this file and `probe.html` are deleted; the modules they exercise
// stay, because they were written as the shipping ones (431).
//
// It reads THE REAL MODULES rather than a copy — `./safari/focal-post.js`,
// `./harvest.js`, `./extractors/registry.js` — so a measurement taken here is a
// measurement of what will ship. That is why the probe page lives inside `src/` instead
// of a sibling `probe/` root: an extension resolves module imports against its root, so a
// `probe/` root could not reach `../src/` without copying the module, and an unchecked
// mirror is the failure [404](../../.change-log/404-the-mirror-nobody-checked.md) exists
// to prevent.
//
// It answers four things in one screen, because they all need the same phone and the same
// tap (096 § T0's riders):
//
//   1. the focal-post hit rate      — the reading, the pick, and the human's verdict
//   2. DOM sufficiency without the hook (§ D5) — the provenance panel's mediaUrl
//   3. the permalink shape per platform (issue 19A) — the provenance panel's originalURL
//   4. whether the page yields geometry at all (issue 17A) — zero-height / no-geometry
//
// Recording goes to `storage.local` and comes back out through a textarea, because a
// phone has nowhere to write a file to.

import { readPostCandidates, chooseFocalPost } from "./safari/focal-post.js";
import { harvestSignals, buildHarvest } from "./harvest.js";
import { extractProvenance } from "./extractors/registry.js";
import { browser } from "./browser.js";

const STORE_KEY = "atelierProbeObservations";

const els = {};
for (const id of [
  "host", "selector", "containers", "linkless", "zerorect", "viewport",
  "basis", "pick", "score", "runner",
  "pPlatform", "pAuthor", "pURL", "pMedia",
  "candidates", "export", "clear", "count", "status", "out",
]) {
  els[id] = document.getElementById(id);
}

/** The last path segment or two of a post URL — enough to recognise a post by eye on a
 * phone, where the full URL wraps to three lines. */
function label(postUrl) {
  try {
    const parts = new URL(postUrl).pathname.split("/").filter(Boolean);
    return parts.slice(-2).join("/") || postUrl;
  } catch {
    return postUrl;
  }
}

function setText(node, value) {
  node.textContent = value === null || value === undefined ? "—" : String(value);
}

/** The stored observations (always an array). */
async function stored() {
  const bag = await browser.storage.local.get(STORE_KEY);
  const list = bag && bag[STORE_KEY];
  return Array.isArray(list) ? list : [];
}

async function refreshCount() {
  const list = await stored();
  els.count.textContent = `${list.length} recorded`;
  return list;
}

/** Render the reading + the pick. Returns nothing; `state` holds what Record needs. */
const state = { reading: null, tabId: null };

function renderReading(reading) {
  setText(els.host, reading.host);
  setText(els.selector, reading.matchedSelector);
  setText(els.containers, reading.containerCount);
  setText(els.linkless, reading.linklessCount);
  setText(els.zerorect, reading.zeroRectCount);
  setText(els.viewport, `${reading.viewport.width}×${reading.viewport.height}`);
  // The two counts that mean "the selector is wrong" and "the page gave no geometry" are
  // called out rather than left as numbers to notice, because the whole point of being on
  // a phone is that noticing is expensive.
  els.linkless.classList.toggle("warn", reading.linklessCount > 0);
  els.zerorect.classList.toggle("warn", reading.zeroRectCount > 0);
}

function renderPick(pick) {
  if (!pick.postUrl) {
    setText(els.basis, pick.reason);
    els.basis.classList.add("warn");
    // `uncapturable-focal` is not "nothing here" — something IS centred, it just has no
    // permalink. Naming which container, and what the nearest capturable thing was, is the
    // whole point of 22A: without it the popup would have quietly captured the alternative.
    if (pick.reason === "uncapturable-focal") {
      setText(els.pick, `container ${pick.index} has no permalink (ad?)`);
      setText(els.score, `${Math.round(pick.score)} / ${Math.round(pick.margin)}`);
      setText(els.runner, pick.alternative ? `would have taken ${label(pick.alternative.postUrl)}` : "nothing capturable");
      return;
    }
    setText(els.pick, "no pick");
    setText(els.score, null);
    setText(els.runner, null);
    return;
  }
  els.basis.classList.remove("warn");
  setText(els.basis, pick.basis);
  setText(els.pick, label(pick.postUrl));
  setText(els.score, `${Math.round(pick.score)} / ${Math.round(pick.margin)}`);
  setText(els.runner, pick.runnerUp ? label(pick.runnerUp.postUrl) : "none");
}

function renderProvenance(provenance) {
  if (!provenance) {
    for (const id of ["pPlatform", "pAuthor", "pURL", "pMedia"]) setText(els[id], null);
    return;
  }
  setText(els.pPlatform, provenance.platform);
  setText(els.pAuthor, provenance.authorHandle || provenance.authorName);
  setText(els.pURL, provenance.originalURL);
  setText(els.pMedia, provenance.mediaUrl);
  // Rider 2 (§ D5): with no hook, a null mediaUrl is the DOM being insufficient, and that
  // is the reading that would send the hook back into the plan.
  els.pMedia.classList.toggle("warn", !provenance.mediaUrl);
}

function renderCandidates(reading, pick) {
  els.candidates.replaceChildren();
  for (const candidate of reading.candidates) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    // An unlinked container is listed and TAPPABLE (22A). Tapping it records
    // `expectedPostUrl: null` — "the thing in the middle was an ad" — which is a real
    // observation, not a spoiled one, and is how the corpus measures ad density alongside
    // the hit rate.
    const name = candidate.postUrl ? label(candidate.postUrl) : "— no link (ad?)";
    // The THUMBNAIL is what makes this list usable. A post id identifies a post to a
    // machine; only x.com's URL happens to identify one to a human (the handle is in the
    // path). On instagram and pinterest the ids are opaque, so without a picture the tap is
    // a guess — and a corpus of guesses looks like evidence while being none.
    if (candidate.thumb) {
      const img = document.createElement("img");
      img.src = candidate.thumb;
      img.alt = "";
      img.className = "thumb";
      button.append(img);
    }
    const caption = document.createElement("span");
    caption.textContent =
      `${candidate.index}. ${name}  [${Math.round(candidate.top)}…${Math.round(candidate.bottom)}]`
      + (candidate.alt ? `\n${candidate.alt.slice(0, 80)}` : "");
    button.append(caption);
    if (pick.index === candidate.index) button.classList.add("chosen");
    button.addEventListener("click", () => record(candidate.postUrl || null));
    item.append(button);
    els.candidates.append(item);
  }
}

/**
 * Append one observation. `expectedPostUrl` is the HUMAN's answer — which post was
 * actually centred — so the corpus records what should have happened, not what did. That
 * is what makes it a regression suite rather than a snapshot of today's behaviour.
 */
async function record(expectedPostUrl) {
  if (!state.reading) return;
  const list = await stored();
  list.push({ reading: state.reading, expectedPostUrl });
  await browser.storage.local.set({ [STORE_KEY]: list });
  const pick = chooseFocalPost(state.reading);
  // `null === null` is a HIT: the code said "the centred thing cannot be captured" and so
  // did the human. That agreement is as much a success as naming the right post.
  els.status.textContent = (pick.postUrl || null) === expectedPostUrl ? "recorded ✓ hit" : "recorded ✗ MISS";
  await refreshCount();
}

async function init() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (!tab || tab.id == null) {
    els.status.textContent = "no active tab";
    return;
  }
  state.tabId = tab.id;

  let reading;
  try {
    const [injection] = await browser.scripting.executeScript({
      target: { tabId: tab.id }, func: readPostCandidates,
    });
    reading = injection && injection.result;
  } catch (error) {
    // Rider 3 (096 § "Gates and risks" 3): this is what a missing per-site permission
    // looks like from the popup, and telling it apart from "nothing here" is the whole
    // question. The message is shown verbatim rather than mapped, because the probe's job
    // is to find out what the message IS.
    els.status.textContent = `executeScript failed: ${error && error.message}`;
    return;
  }
  if (!reading) {
    els.status.textContent = "no reading";
    return;
  }
  state.reading = reading;
  renderReading(reading);

  const pick = chooseFocalPost(reading);
  renderPick(pick);
  renderCandidates(reading, pick);

  // Riders 2 + 19A: run the SHIPPING harvest + extractors against the chosen post, exactly
  // as tier 3 will (the chosen postUrl threads in as `context.linkUrl`, which is the seam
  // 431 was built around).
  if (pick.postUrl) {
    try {
      const [harvested] = await browser.scripting.executeScript({
        target: { tabId: tab.id }, func: harvestSignals,
      });
      const harvest = buildHarvest(harvested && harvested.result);
      renderProvenance(extractProvenance(harvest, { linkUrl: pick.postUrl }));
    } catch (error) {
      els.status.textContent = `harvest failed: ${error && error.message}`;
    }
  } else {
    renderProvenance(null);
  }

  await refreshCount();
}

els.export.addEventListener("click", async () => {
  const list = await stored();
  els.out.hidden = false;
  els.out.value = JSON.stringify(list, null, 2);
  els.out.select();
});

els.clear.addEventListener("click", async () => {
  await browser.storage.local.set({ [STORE_KEY]: [] });
  els.out.hidden = true;
  els.status.textContent = "cleared";
  await refreshCount();
});

// Anything that escapes `init` lands in the status line. On a phone there is no console to
// open, and a silent failure is indistinguishable from the page never having loaded — which
// is exactly how the missing <script> tag presented: every field stuck on its placeholder.
init().catch((error) => {
  els.status.textContent = `probe failed: ${error && error.message ? error.message : String(error)}`;
});
