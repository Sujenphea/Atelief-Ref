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
// It answers five things in one screen, because they all need the same phone and the same
// tap (096 § T0's riders):
//
//   1. the focal-post hit rate      — the reading, the pick, and the human's verdict
//   2. DOM sufficiency without the hook (§ D5) — the provenance panel's mediaUrl
//   3. the permalink shape per platform (issue 19A) — the provenance panel's originalURL
//   4. whether the page yields geometry at all (issue 17A) — zero-height / no-geometry
//   5. a RAW `harvestSignals` dump per platform (issue 12B) — the live page shape that
//      `PageExtractorTests`' hand-composed fixtures cannot prove anything about
//
// Recording goes to `storage.local` and comes back out through a textarea, because a
// phone has nowhere to write a file to.

import { readPostCandidates, chooseFocalPost } from "./safari/focal-post.js";
import { harvestSignals, buildHarvest } from "./harvest.js";
import { extractProvenance } from "./extractors/registry.js";
import { browser } from "./browser.js";

const STORE_KEY = "atelierProbeObservations";
/** Kept apart from the observations, and keyed by HOST rather than appended (12B).
 *
 * One dump is tens of KB where an observation is a few hundred bytes, so appending 90 of
 * them would make the corpus export unreadable on a phone for no gain — the fixture wants
 * a few real pages, not ninety. Keying by PAGE URL rather than appending makes re-dumping
 * the obvious thing: the first attempt on a feed is usually taken before the images have
 * loaded, and last-wins means correcting it is a second tap rather than a hunt through an
 * array.
 *
 * Keyed by page URL rather than by host because a feed and an open post are DIFFERENT
 * pages that both need capturing, for different consumers — see `pageKindOf`. Keying by
 * host would silently let one overwrite the other. */
const SIGNALS_KEY = "atelierProbeSignals";

const els = {};
for (const id of [
  "host", "selector", "containers", "linkless", "zerorect", "viewport",
  "basis", "pick", "score", "runner",
  "pPlatform", "pAuthor", "pURL", "pMedia",
  "candidates", "export", "dump", "clear", "count", "status", "out", "signals",
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

/** The stored signal dumps, keyed by host (always an object). */
async function storedSignals() {
  const bag = await browser.storage.local.get(SIGNALS_KEY);
  const map = bag && bag[SIGNALS_KEY];
  return map && typeof map === "object" && !Array.isArray(map) ? map : {};
}

async function refreshSignals() {
  const map = await storedSignals();
  const entries = Object.values(map);
  // Host + kind, because "x.com feed" and "x.com post" are the two things that have to be
  // there and a bare host list would look complete with only one of them.
  const summary = entries.map((entry) => `${entry.host}·${entry.pageKind}`);
  els.signals.textContent = summary.length ? `signals: ${summary.join(", ")}` : "signals: none";
  return map;
}

/**
 * A copy of the raw snapshot with every rasterized video frame removed.
 *
 * Three reasons, and only the third is about size. A frame is a JPEG data-URL of
 * WHATEVER WAS ON THE USER'S SCREEN, and this fixture gets committed. `RawPageSignals` on
 * the Swift side has no `frame` field at all — Safari's preprocessing script cannot draw a
 * canvas — so a frame could never be replayed there, and a fixture whose two replays read
 * different media lists is worse than one that carries neither. And it is by far the
 * largest thing in the snapshot.
 *
 * `frameStripped` marks the videos that HAD one, so the fixture says what was removed
 * rather than quietly presenting a frameless page as the page that was seen.
 */
/**
 * `"post"` when the chosen permalink IS the page being looked at, `"feed"` otherwise.
 *
 * This is not a label for tidiness; it decides which replays can use the entry.
 * `extractProvenance` takes a `linkUrl` — on a feed, tier 3 tells it which of forty posts
 * was centred. Swift's `PageExtractor.capture(from:)` takes NO such context: tier 2 sees
 * a page Safari preprocessed and dispatches on that page's own URL, because a share sheet
 * has no right-clicked link to pass. So on a feed dump the two languages are answering
 * different questions and MUST disagree — Swift would report `x.com/home`, which is not a
 * post. Only on a post page do they converge, and only there is a cross-language
 * comparison a drift check rather than a category error.
 *
 * Compared on origin + pathname: the permalink is clean where `location.href` routinely
 * carries a tracking query or a scroll hash.
 */
function pageKindOf(pageUrl, linkUrl) {
  if (!linkUrl) return "feed";
  try {
    const page = new URL(pageUrl);
    const link = new URL(linkUrl);
    const same = page.origin === link.origin
      && page.pathname.replace(/\/+$/, "") === link.pathname.replace(/\/+$/, "");
    return same ? "post" : "feed";
  } catch {
    return "feed";
  }
}

function stripFrames(raw) {
  return {
    ...raw,
    videos: (raw.videos || []).map((video) => {
      const { frame, ...rest } = video;
      return frame ? { ...rest, frame: null, frameStripped: true } : { ...rest, frame: null };
    }),
  };
}

/** Render the reading + the pick. Returns nothing; `state` holds what Record needs. */
const state = { reading: null, tabId: null, rawSignals: null, provenance: null, linkUrl: null };

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
      // The RAW snapshot is held as well as the classified one, because 12B's fixture is
      // the raw shape: it is what both `buildHarvest` and Swift's `PageHarvest.build`
      // consume, and classifying before storing would freeze one language's reading of the
      // page into the fixture the other is supposed to be checked against.
      const raw = harvested && harvested.result;
      const harvest = buildHarvest(raw);
      const provenance = extractProvenance(harvest, { linkUrl: pick.postUrl });
      state.rawSignals = raw || null;
      state.provenance = provenance || null;
      state.linkUrl = pick.postUrl;
      renderProvenance(provenance);
    } catch (error) {
      els.status.textContent = `harvest failed: ${error && error.message}`;
    }
  } else {
    renderProvenance(null);
  }

  await refreshCount();
  await refreshSignals();
}

/**
 * Store the current page's RAW signals as this host's live fixture (12B).
 *
 * **The expectation is the human's, exactly as it is for a tap.** What goes in beside the
 * raw snapshot is the provenance ON SCREEN — so this button is only pressed when the
 * provenance card reads correctly for the post being looked at. Recording the code's own
 * answer unexamined would make the fixture a snapshot test that locks in whatever the
 * extractor did on the day, bugs and all; recording an answer a person has just read off
 * the screen makes it the same kind of evidence the focal-post tap is.
 *
 * Requires a pick, because a provenance with no `linkUrl` is not what tier 3 will ever
 * ask the extractors for.
 */
async function dumpSignals() {
  if (!state.rawSignals || !state.provenance || !state.reading) {
    els.status.textContent = "nothing to dump — no reading, pick or provenance";
    return;
  }
  const map = await storedSignals();
  const pageUrl = state.rawSignals.url || state.reading.url;
  map[pageUrl] = {
    host: state.reading.host,
    pageUrl,
    pageKind: pageKindOf(pageUrl, state.linkUrl),
    capturedAt: new Date().toISOString(),
    linkUrl: state.linkUrl,
    // Only the fields both languages produce. `PageExtractor` on Swift has no notion of
    // the extension's extras, and a fixture asserting a field one side cannot compute
    // would fail as drift while nothing had drifted.
    expected: {
      platform: state.provenance.platform ?? null,
      authorHandle: state.provenance.authorHandle ?? null,
      authorName: state.provenance.authorName ?? null,
      originalURL: state.provenance.originalURL ?? null,
      title: state.provenance.title ?? null,
      mediaUrl: state.provenance.mediaUrl ?? null,
      mediaUrlFallback: state.provenance.mediaUrlFallback ?? null,
    },
    raw: stripFrames(state.rawSignals),
  };
  await browser.storage.local.set({ [SIGNALS_KEY]: map });
  const bag = await refreshSignals();
  els.status.textContent = `dumped ${state.reading.host} (${map[pageUrl].pageKind})`;
  // The WHOLE bag is rendered, not just this dump: the end-of-session copy is then one
  // tap rather than three, and a host that was expected and is missing is visible in the
  // same glance.
  els.out.hidden = false;
  els.out.value = JSON.stringify(bag, null, 2);
}

els.dump.addEventListener("click", () => {
  dumpSignals().catch((error) => {
    els.status.textContent = `dump failed: ${error && error.message ? error.message : String(error)}`;
  });
});

els.export.addEventListener("click", async () => {
  const list = await stored();
  els.out.hidden = false;
  els.out.value = JSON.stringify(list, null, 2);
  els.out.select();
});

els.clear.addEventListener("click", async () => {
  await browser.storage.local.set({ [STORE_KEY]: [], [SIGNALS_KEY]: {} });
  els.out.hidden = true;
  els.status.textContent = "cleared";
  await refreshCount();
  await refreshSignals();
});

// Anything that escapes `init` lands in the status line. On a phone there is no console to
// open, and a silent failure is indistinguishable from the page never having loaded — which
// is exactly how the missing <script> tag presented: every field stuck on its placeholder.
init().catch((error) => {
  els.status.textContent = `probe failed: ${error && error.message ? error.message : String(error)}`;
});
