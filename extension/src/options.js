// Atelier Capture — options page: store the shared-secret token.

const TOKEN_KEY = "atelierToken";
const input = document.getElementById("token");
const status = document.getElementById("status");

chrome.storage.local.get(TOKEN_KEY).then((stored) => {
  input.value = stored[TOKEN_KEY] || "";
});

document.getElementById("save").addEventListener("click", async () => {
  await chrome.storage.local.set({ [TOKEN_KEY]: input.value.trim() });
  status.textContent = "Saved.";
  setTimeout(() => (status.textContent = ""), 2000);
});
