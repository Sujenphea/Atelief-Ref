// Atelier Capture — sweep-context resolver (the popup's "which sweep is this tab?").
//
// PURE + INJECTABLE, mirroring the drivers: it takes the raw page inputs the popup
// gathers over the executeScript boundary — the tab `url` and (Pinterest only) the
// board's `collageHref` — and returns EITHER a launchable sweep spec OR a typed reason
// the popup renders as guidance. No chrome.*/DOM here, so the whole eligibility matrix
// (right site? right page? board id present?) is unit-tested against real-shaped input.
//
//   resolveSweepSpec({ url, collageHref }) ->
//     { ok: true,  spec: { platform, input, scope } }
//     { ok: false, reason: "not-supported-site" | "not-a-board"
//                        | "board-id-missing"   | "x-not-bookmarks" }
//
// Pinterest board id: NOT in a bootstrap JSON (Pinterest isn't a Next.js app — there's
// no __NEXT_DATA__). It lives in the "Collage" button's href on the board page —
// `/collage-creation-tool/?boardId=<digits>` — which the popup reads from the DOM. That
// button is the current board's, so no slug disambiguation is needed.
//
// `spec` carries NO `resolveVideo` and NO `expandNotes` — those are user toggles the popup
// folds in before building the start message; the resolver only decides WHAT can be swept,
// not HOW. Both follow the same rule, deliberately: a toggle answers a question the page
// cannot (does this user want the video bytes? the slow per-note expansion?), so putting
// one here would make the resolver's answer depend on something it cannot see.

import { splitPathname } from "./extractors/base.js";

/** Pinterest first-path-segments that are app routes, not a user's board slug — so
 * `/pin/123/`, `/search/pins/`, `/settings/` are never mistaken for `/user/board/`. */
const PINTEREST_RESERVED = new Set([
  "pin", "search", "settings", "ideas", "today", "news_hub", "business",
  "login", "signup", "categories", "discover", "videos", "_saved", "_created",
]);

/** Classify a hostname into our supported platforms (null = unsupported). Matches the
 * manifest host scopes: any `*.pinterest.<tld>` and x.com / twitter.com (± www). */
export function platformForHost(hostname) {
  const host = (hostname || "").toLowerCase();
  if (/(^|\.)pinterest\.[a-z.]+$/.test(host)) return "pinterest";
  if (/(^|\.)(x|twitter)\.com$/.test(host)) return "twitter";
  if (/(^|\.)instagram\.com$/.test(host)) return "instagram";
  // One product, two domains — rednote.com (international) and xiaohongshu.com
  // (mainland). Both are in host_permissions and both must resolve here.
  if (/(^|\.)(rednote|xiaohongshu)\.com$/.test(host)) return "rednote";
  return null;
}

/** The `{ user, slug, boardUrl }` for a plain board page `/<user>/<slug>/`, or null
 * for anything else (home, profile, pin, search, a board SECTION at depth 3, …).
 * Conservative on purpose: only the depth-2 board page is verified (doc 019 T1). */
export function pinterestBoardPath(pathname) {
  const segments = splitPathname(pathname);
  if (segments.length !== 2) return null;
  const [user, slug] = segments;
  if (PINTEREST_RESERVED.has(user)) return null;
  return { user, slug, boardUrl: `/${user}/${slug}/` };
}

/** The numeric board id out of the "Collage" button href
 * (`/collage-creation-tool/?boardId=1084663960195879466`), or null if the href is
 * absent/mis-shaped (→ the popup shows `board-id-missing`, the honest "couldn't read
 * it, reload" signal). Parsed via `URL` so a relative href and extra query params are
 * handled; the id must be all digits to reject a stray non-board link. */
export function extractPinterestBoardId(collageHref) {
  if (typeof collageHref !== "string" || collageHref.length === 0) return null;
  let boardId;
  try {
    boardId = new URL(collageHref, "https://www.pinterest.com").searchParams.get("boardId");
  } catch {
    return null;
  }
  return boardId && /^\d+$/.test(boardId) ? boardId : null;
}

/**
 * Resolve the active tab into a launchable sweep spec, or a typed refusal reason.
 * @param url         the tab's full URL string.
 * @param collageHref Pinterest only: the "Collage" button's href (the popup reads it
 *                    from the board-page DOM over executeScript). Ignored for X.
 */
export function resolveSweepSpec({ url, collageHref = null } = {}) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return { ok: false, reason: "not-supported-site" };
  }

  const platform = platformForHost(parsed.hostname);
  if (!platform) return { ok: false, reason: "not-supported-site" };

  if (platform === "twitter") {
    // The X driver ignores `input` and ingests whatever timeline the page fetches — so
    // launching anywhere but a bookmarks page would sweep the wrong feed (home). Allow
    // the main tab (`/i/bookmarks`) AND a bookmark folder (`/i/bookmarks/<id>`): both
    // are bookmark timelines the hook can read. The folder id isn't needed to enumerate
    // (the page fetches the folder's own timeline), only to SCOPE the sweep so a
    // folder's resume/checkpoint doesn't collide with the main tab or another folder.
    const match = /^\/i\/bookmarks(?:\/(\d+))?\/?$/.exec(parsed.pathname);
    if (match) {
      const folderId = match[1] || null;
      return {
        ok: true,
        spec: { platform, input: {}, scope: folderId ? `bookmarks:${folderId}` : "bookmarks" },
      };
    }
    return { ok: false, reason: "x-not-bookmarks" };
  }

  if (platform === "instagram") {
    // Two saved sweeps, both under `/{user}/saved/`:
    //   · Flat "All saved" — `/{user}/saved/` or `/{user}/saved/all-posts/` → scope "saved".
    //   · A specific COLLECTION — `/{user}/saved/{slug}/{collectionId}/` (numeric id,
    //     verified live 2026-07-16) → the collection feed. Scope by the STABLE numeric id
    //     (a rename changes the slug, not the id, so a resume never collides / re-walks);
    //     the slug rides along in `input` for the popup label only. `input.collectionId`
    //     is what the driver reads to hit `…/feed/collection/<id>/posts/`.
    // The driver otherwise ignores `input`. A saved subpath matching neither shape (e.g. a
    // slug with no id) is refused clearly rather than swept as the wrong feed; a non-saved
    // IG page is refused too.
    const segments = splitPathname(parsed.pathname);
    if (segments[1] === "saved") {
      if (segments.length === 2 || (segments.length === 3 && segments[2] === "all-posts")) {
        return { ok: true, spec: { platform, input: {}, scope: "saved" } };
      }
      if (segments.length === 4 && /^\d+$/.test(segments[3])) {
        const collectionId = segments[3];
        return {
          ok: true,
          spec: {
            platform,
            input: { collectionId, collectionSlug: segments[2] },
            scope: `saved:collection:${collectionId}`,
          },
        };
      }
      return { ok: false, reason: "instagram-saved-unrecognized" };
    }
    return { ok: false, reason: "instagram-not-saved" };
  }

  if (platform === "rednote") {
    // A board lives at `/board/<id>`. The id is a 24-char hex object id (verified in the
    // live board-feed request: `board_id=69322476000000001202811f`) — NOT digits, so
    // Pinterest's `/^\d+$/` rule cannot be reused here.
    //
    // The id is required, and it is required for a reason beyond labelling: the driver
    // scopes on it (`matchesScope`), and the hook's replay buffer can hold pages from a
    // board visited earlier in the same tab. Without the id we could not tell one board's
    // replayed pages from another's, so a sweep that cannot name its board is refused.
    const segments = splitPathname(parsed.pathname);
    if (segments[0] !== "board") return { ok: false, reason: "rednote-not-a-board" };
    const boardId = segments[1] && /^[0-9a-f]{16,32}$/i.test(segments[1]) ? segments[1] : null;
    if (!boardId) return { ok: false, reason: "rednote-board-id-missing" };
    return {
      ok: true,
      spec: { platform, input: { boardId }, scope: `board:${boardId}` },
    };
  }

  // Pinterest: must be a board page, and we must recover its board id.
  const board = pinterestBoardPath(parsed.pathname);
  if (!board) return { ok: false, reason: "not-a-board" };

  const boardId = extractPinterestBoardId(collageHref);
  if (!boardId) return { ok: false, reason: "board-id-missing" };

  return {
    ok: true,
    spec: {
      platform,
      input: { boardId, boardUrl: board.boardUrl },
      scope: `board:${board.slug}`,
    },
  };
}

/** Human-facing message for each refusal reason — the popup's single source of copy
 * so the strings live next to the reasons that produce them. */
export const REASON_MESSAGE = Object.freeze({
  "not-supported-site": "Open a Pinterest board, x.com/i/bookmarks, or your Instagram saved posts to start a sweep.",
  "not-a-board": "This isn't a Pinterest board page. Open a board (pinterest.com/you/board/).",
  "board-id-missing": "Couldn't read this board's id — reload the board page and try again.",
  "x-not-bookmarks": "Open x.com/i/bookmarks to sweep your bookmarks.",
  "instagram-not-saved": "Open your Instagram saved posts (instagram.com/<you>/saved/) to start a sweep.",
  "instagram-saved-unrecognized":
    "Couldn't tell which saved feed this is — open your All posts (…/saved/all-posts/) or a specific collection to sweep.",
  "rednote-not-a-board":
    "This isn't a rednote board. Open a board (rednote.com/board/…) to start a sweep.",
  "rednote-board-id-missing":
    "Couldn't read this board's id from the URL — open the board from your profile and try again.",
});
