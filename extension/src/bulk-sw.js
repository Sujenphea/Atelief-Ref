// Atelier Capture — service-worker bulk message handler (Phase 6).
//
// The SW half of the bulk protocol: the content-script controller messages the SW
// for every localhost op (only the SW can reach 127.0.0.1). This is the pure,
// injectable dispatcher — `handleBulkMessage(message, deps)` — with all
// collaborators (the /jobs wrappers, `ingestOne`, the token) injected, so the whole
// open/known/relay/complete matrix is unit-tested with no chrome.* and no network.
// The thin `chrome.runtime.onMessage` glue that supplies the real deps lives in
// sw.js.

import { BULK } from "./bulk-messages.js";
import { isAllowedMediaHost } from "./media-hosts.js";

/**
 * Dispatch one bulk message to its app-side effect and return the reply payload.
 * `relay` runs `ingestOne` (the SAME per-item tail single-item capture uses, C5) so
 * a bulk item and a manual capture ingest identically; the content script classifies
 * the returned result into an outcome. Throws on an unknown type (the caller reports
 * it back as an error reply). Video stays opt-in: `mp4Url` is relayed only when the
 * controller asked to resolve video.
 */
export async function handleBulkMessage(message, {
  token, fetchImpl, ingestOne, openJob, fetchKnownSources, completeJob,
}) {
  switch (message.type) {
    case BULK.open:
      return await openJob(
        {
          platform: message.platform, scope: message.scope,
          totalEstimate: message.totalEstimate, resumeJobId: message.resumeJobId,
        },
        { token, fetchImpl });

    case BULK.known:
      return await fetchKnownSources(message.jobId, { token, fetchImpl });

    case BULK.relay: {
      // SSRF guard (3A): the media URLs rode in on a page-supplied response, and the SW
      // is about to fetch them with host_permissions in the authenticated session. Refuse
      // any URL that isn't on the platform's media CDN allowlist BEFORE fetching — a
      // blocked item is a permanent per-item failure (classified via the default arm),
      // never a network call to an arbitrary host.
      const provenance = message.provenance || {};
      const mp4Url = message.mp4Url || null;
      const platform = provenance.platform;
      const candidates = [provenance.mediaUrl, provenance.mediaUrlFallback, mp4Url].filter(Boolean);
      const blocked = candidates.find((url) => !isAllowedMediaHost(platform, url));
      if (blocked) {
        return { status: "blocked-host", message: `refused non-CDN media host: ${blocked}` };
      }
      return await ingestOne(provenance, {
        token,
        mp4Url,
        jobId: message.jobId,
        sourceId: message.sourceId,
        caps: message.caps || null, // server byte caps (13A) — enforced pre-download
      });
    }

    case BULK.complete:
      return await completeJob(message.jobId, message.status || "complete", { token, fetchImpl });

    default:
      throw new Error(`unknown bulk message: ${message.type}`);
  }
}
