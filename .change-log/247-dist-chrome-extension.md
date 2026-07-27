# 247 — Chrome extension distribution (packaging + privacy)

Phase **A5** of the distribution plan (`.docs/052-distribution-export-plan.md`):
package the MV3 Atelier Capture extension for the Chrome Web Store and write a
privacy policy. No signing/store upload is automated — this is the packaging +
human-TODO surface.

## Summary

- Added `scripts/package-extension.sh` — builds the Web Store upload zip from
  `extension/`, stripping dev cruft (`.DS_Store`, `.git`, `node_modules`, source
  maps, `test/`, `scripts/`, `package.json`, `README.md`, `.gitignore`) and
  placing `manifest.json` at the zip root (store requirement). Stock tools only
  (rsync + zip), one step per function (decision 6A). Output:
  `dist/atelier-capture-<version>.zip`. Verified run produced a 92K clean zip.
- Wrote `extension/PRIVACY.md` — honest to the code: captures go only to the
  local loopback app (`http://127.0.0.1:47321`); no remote server, no analytics,
  no account; token + sweep checkpoints live in `chrome.storage.local`; host
  permissions used to read the captured page and fetch its media in-session.
- Wrote `extension/STORE-LISTING.md` — dashboard checklist (listing fields,
  graphics sizes, privacy disclosures, permission justifications, submission).
- Ignored `/dist/` in `.gitignore`.

## Manifest audit

- Present + valid: `manifest_version: 3`, `name`, `version` (0.1.0),
  `description`.
- **Missing: all icons.** No `icons` key, no `action.default_icon`, and **no
  source icon image exists anywhere in the repo** — so the standard 16/32/48/128
  set could NOT be auto-generated (nothing to resize). This is a hard blocker for
  store upload and is documented as section 0 of STORE-LISTING.md. The manifest
  was intentionally NOT modified to reference not-yet-existing icon files (Chrome
  errors on a missing icon path).
- Permissions are minimal and justified: `activeTab`, `scripting`, `storage`,
  `contextMenus`. Host permissions (loopback + X/Pinterest/Instagram/Cosmos and
  their CDNs) will draw store review scrutiny and need the listed justification.

## Files

- Added: `scripts/package-extension.sh` (executable)
- Added: `extension/PRIVACY.md`
- Added: `extension/STORE-LISTING.md`
- Modified: `.gitignore` (ignore `/dist/`)

## Migration notes

- Before first store upload, supply extension icons and add the `icons` /
  `action.default_icon` block per STORE-LISTING.md §0, then re-run the packaging
  script.
- Host `PRIVACY.md` at a public URL for the store's required privacy-policy field.
