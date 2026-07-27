# Chrome Web Store — listing checklist (Atelier Capture)

Human TODO surface for submitting Atelier Capture to the Chrome Web Store. The
extension code + upload zip are produced by `scripts/package-extension.sh`; the
items below are the things only you can supply in the developer dashboard.

## 0. Blocker before first upload — ICONS

The extension ships **no icons**. The manifest currently has **no `icons` key**
and the action has **no `default_icon`**. The Chrome Web Store requires at least a
128×128 store icon, and Chrome uses 16/32/48/128 for the toolbar, management page,
and installation dialog.

**Action required (needs artwork — not auto-generatable, no source image exists):**

1. Provide a square source PNG (ideally 512×512 or larger) for the extension logo.
2. Produce the standard sizes (on macOS, `sips` can resize a source PNG):
   ```
   sips -z 16 16   icon-512.png --out extension/icons/icon-16.png
   sips -z 32 32   icon-512.png --out extension/icons/icon-32.png
   sips -z 48 48   icon-512.png --out extension/icons/icon-48.png
   sips -z 128 128 icon-512.png --out extension/icons/icon-128.png
   ```
3. Add to `manifest.json`:
   ```json
   "icons": {
     "16": "icons/icon-16.png",
     "32": "icons/icon-32.png",
     "48": "icons/icon-48.png",
     "128": "icons/icon-128.png"
   },
   ```
   and set `action.default_icon` to the same set.
4. Re-run `scripts/package-extension.sh` (icons/ is included automatically).

Do **not** add the `icons` key pointing at files that don't exist yet — Chrome
raises a load error for a missing icon file.

## 1. Store listing fields (dashboard → Store listing)

- **Name:** Atelier Capture (from manifest)
- **Summary / short description:** "Save the current post/pin (with provenance)
  to ref-atelier." (from manifest — max 132 chars)
- **Detailed description:** Write a longer description. Cover: what it does
  ("save as you browse" to a local reference library), that it pairs with the
  **Atelier desktop app running on the same machine**, supported sites
  (Twitter/X, Pinterest, Instagram, Cosmos, + Open-Graph fallback), single
  capture vs. bulk sweeps, and that captures stay on your device.
- **Category:** Productivity (suggested) — confirm in dashboard.
- **Language:** English.

## 2. Graphic assets (dashboard → Store listing)

All must be supplied by you; none exist in the repo.

- **Store icon:** 128×128 PNG (see section 0).
- **Screenshots:** at least 1, up to 5. Required size **1280×800** or **640×400**
  PNG/JPEG. Suggested shots: the right-click "Save to Atelier" menu; the bulk-sweep
  popup; the app receiving a capture.
- **Small promo tile (optional but recommended):** 440×280 PNG/JPEG.
- **Marquee promo tile (optional):** 1400×560 PNG/JPEG.

## 3. Privacy practices (dashboard → Privacy)

- **Single purpose description:** "Capture the image/video/post the user is
  viewing and save it, with provenance, to the user's local Atelier desktop app."
- **Permission justifications** (the store asks for each — see also PRIVACY.md):
  - `activeTab` + `scripting` — read the media/provenance from the tab the user
    is capturing, only on user action.
  - `storage` — store the local pairing token and bulk-sweep resume checkpoints.
  - `contextMenus` — add the "Save to Atelier" right-click item.
  - **Host permissions** (these draw the most review scrutiny — justify clearly):
    - `http://127.0.0.1/*` — deliver captures to the local Atelier desktop app
      over loopback.
    - X / Pinterest / Instagram / Cosmos site + CDN hosts — read those pages and
      download the exact media the user is saving, in the user's own session.
- **Remote code:** "No" — the extension executes no remotely-hosted code (all JS
  is bundled; content scripts run only bundled `src/*.js`).
- **Data usage disclosures:** Declare that the extension does **not** collect or
  transmit user data to the developer or any third party. Data goes only to the
  user's own machine (loopback). No analytics. Check the certification boxes:
  not sold to third parties, not used for unrelated purposes, not used for
  creditworthiness/lending.
- **Privacy policy URL:** REQUIRED because host permissions are requested. Host
  `extension/PRIVACY.md` at a public URL (e.g. GitHub raw / Pages / a project
  site) and paste that URL here.

## 4. Distribution (dashboard → Distribution)

- **Visibility:** Public / Unlisted / Private — decide. Given the app pairing
  requirement, **Unlisted** may suit an early release.
- **Regions:** all, or restrict.
- **Pricing:** Free.

## 5. Submission steps (only you can do these)

1. Register/verify a **Chrome Web Store developer account** (one-time US$5 fee).
2. Verify the publisher email / set up a group publisher if desired.
3. Resolve the **icons blocker** (section 0) and re-run the packaging script.
4. **Upload** `dist/atelier-capture-<version>.zip`.
5. Fill in listing fields (section 1), upload graphics (section 2), complete the
   privacy tab incl. the privacy-policy URL (section 3), set distribution
   (section 4).
6. **Submit for review.** First-review turnaround is typically a few days; a
   listing with broad host permissions may get extra scrutiny — the
   justifications above are what the reviewer reads.
7. On each future release: bump `version` in `manifest.json`, re-run the
   packaging script, upload the new zip.
