// Atelier Capture — options page: the shared-secret token and the capture target.

import { BASE_OVERRIDE_KEY, BASE_CACHE_KEY } from "./base-url.js";
import { browser } from "./browser.js";

const TOKEN_KEY = "atelierToken";
const input = document.getElementById("token");
const target = document.getElementById("target");
const status = document.getElementById("status");

browser.storage.local.get([TOKEN_KEY, BASE_OVERRIDE_KEY]).then((stored) => {
  input.value = stored[TOKEN_KEY] || "";
  target.value = stored[BASE_OVERRIDE_KEY] || "auto";
});

document.getElementById("save").addEventListener("click", async () => {
  await browser.storage.local.set({
    [TOKEN_KEY]: input.value.trim(),
    [BASE_OVERRIDE_KEY]: target.value,
  });
  // Drop the probe result too: the user may have just repointed at the other app,
  // and a stale cached base would keep winning until something failed (301).
  await browser.storage.local.remove(BASE_CACHE_KEY);
  status.textContent = "Saved.";
  setTimeout(() => (status.textContent = ""), 2000);
});
