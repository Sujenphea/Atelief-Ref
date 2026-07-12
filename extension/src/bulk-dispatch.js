// Atelier Capture — sweep dispatch (send the start message; heal a cold tab).
//
// PURE + INJECTABLE: `sendMessage` (chrome.tabs.sendMessage) and `injectScript`
// (chrome.scripting.executeScript of the bulk loader) are deps, so the branchy part —
// happy send, and the "content script isn't on this tab" recovery — is unit-tested
// with fakes. Only the ~3-line wiring of the real chrome.* fns stays in the popup.
//
// Why recovery is needed: a tab open BEFORE the extension (re)loaded has no content
// script, so the first send rejects with "Receiving end does not exist" (doc 019).
// The fix is to inject the loader and retry — the common fresh-install-then-click
// case. We don't string-match the chrome error (it's localized/brittle); injecting is
// idempotent (the module is cached + the controller's `__atelierBulkController` guard),
// so recovering on ANY first failure is safe and simpler.
//
// The retry LOOP tolerates the async gap between injection and the controller
// registering its listener: a not-yet-ready tab rejects the send FAST (nothing
// started), so we back off and try again; the send that finally connects starts the
// sweep exactly once and resolves with the controller's reply.

import { buildStartMessage } from "./bulk-messages.js";

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Send the `START` message for `spec` to the target tab; on a first failure, inject
 * the controller and retry until it answers.
 * @returns the controller's reply — `{ ok: true, result }` or `{ ok: false, error }`
 *   (a resolved error reply is NOT a transport failure, so it's returned as-is, not
 *   retried; only a thrown/rejected send triggers injection).
 * @throws if the controller stays unreachable after injecting + all retries.
 */
export async function dispatchStart({
  sendMessage, injectScript, spec, sleep = defaultSleep, retries = 6, retryDelayMs = 150,
}) {
  const message = buildStartMessage(spec);

  try {
    return await sendMessage(message);
  } catch {
    // No receiver — inject the loader, then poll for the freshly-registered listener.
    try {
      await injectScript();
    } catch (injectError) {
      throw new Error(`couldn't inject the sweep controller: ${describe(injectError)}`);
    }

    let lastError;
    for (let attempt = 0; attempt < retries; attempt += 1) {
      await sleep(retryDelayMs);
      try {
        return await sendMessage(message);
      } catch (error) {
        lastError = error;
      }
    }
    throw new Error(`sweep controller unreachable after injecting: ${describe(lastError)}`);
  }
}

function describe(error) {
  return error && error.message ? error.message : String(error);
}
