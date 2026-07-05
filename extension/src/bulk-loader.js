// Atelier Capture — ISOLATED-world module loader (Phase 6).
//
// A manifest content script (`js`) is a CLASSIC script — it can't `import`. The bulk
// controller is an ES-module graph, so this tiny classic loader dynamic-imports it
// (dynamic `import()` IS allowed from a content script when the module + its graph
// are `web_accessible_resources`). The controller's guarded bootstrap then registers
// its runtime-message listener. Kept separate + import-free so it loads standalone.

import(chrome.runtime.getURL("src/bulk-controller.js")).catch((error) => {
  console.error("[Atelier] bulk controller failed to load:", error);
});
