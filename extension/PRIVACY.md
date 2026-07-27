# Privacy Policy — Atelier Capture

_Last updated: 2026-07-27_

Atelier Capture is a Chrome extension that saves the image, video, or post you
are looking at into **Atelier**, a reference-management app that runs on your own
computer. This policy describes exactly what data the extension handles and where
it goes.

## The short version

- The extension sends the content you capture to a **local server on your own
  machine** (the Atelier desktop app, at `http://127.0.0.1:47321`). This is a
  loopback address — the request never leaves your computer.
- **No data is sent to the extension's developer, to any remote server, or to any
  third-party service.**
- There is **no analytics, no telemetry, and no tracking** of any kind.
- There is **no account and no sign-in.**
- Everything you capture stays **on your device**, inside your Atelier library.

## What the extension does

When you right-click an image/pin/post and choose "Save to Atelier", or run a
bulk sweep of a feed you are viewing, the extension:

1. Reads signals from the page you are on (the media URL, the post link, title,
   author, and Open-Graph / page metadata).
2. Fetches the media bytes (image or video) **in your own logged-in browser
   session**, so content behind a login works.
3. Sends those bytes plus the collected provenance to the Atelier desktop app on
   `http://127.0.0.1:47321`, authenticated with a pairing token you set up once.

The desktop app stores the result in your local library. The extension keeps no
copy.

## Data the extension stores locally

The extension uses `chrome.storage.local` (on your device only) for two things:

- **A pairing token** — the shared secret that authorizes the extension to talk
  to your local Atelier app. You paste it once on the options page.
- **Bulk-sweep checkpoints** — progress markers so an interrupted sweep can
  resume and skip items already saved.

Neither is transmitted anywhere except to your local Atelier app.

## Network connections the extension makes

- **`http://127.0.0.1` (loopback / your own machine)** — to send captured content
  and provenance to the Atelier desktop app, and to check that the app is running
  and version-compatible.
- **The sites you are capturing from and their content CDNs** — Twitter/X
  (`x.com`, `twitter.com`, `twimg.com`), Pinterest (`pinterest.com`,
  `pinterest.co.uk`, `pinimg.com`), Instagram (`instagram.com`,
  `cdninstagram.com`, `fbcdn.net`), and Cosmos (`cosmos.so`). These connections
  read the page and download the exact image/video you are saving, in your
  existing session. They go to the same platforms you are already browsing — the
  extension does not introduce any new third-party recipient of your data.

## Why the extension requests each permission

- **`activeTab` / `scripting`** — to read the media and provenance from the tab
  you are actively capturing from, only when you invoke a capture.
- **`storage`** — to keep the pairing token and sweep checkpoints (above).
- **`contextMenus`** — to add the "Save to Atelier" right-click item.
- **Host permissions for X / Pinterest / Instagram / Cosmos and their CDNs** — to
  read those pages and fetch the media you capture from them in your session.
- **Host permission for `http://127.0.0.1`** — to deliver captures to the local
  Atelier app.

## Data sharing and sale

We do not collect, sell, share, or transfer your data to anyone. There is no
server operated by the developer that receives any of your data.

## Changes to this policy

If the extension's data handling changes, this document will be updated and its
"Last updated" date revised.

## Contact

For questions about this policy, contact the developer at the email listed on the
extension's Chrome Web Store listing.
