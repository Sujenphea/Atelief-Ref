#!/usr/bin/env bash
#
# package-extension.sh — build the Chrome Web Store upload zip for the
# Atelier Capture MV3 extension.
#
# Decision 6A style: explicit over clever. One step per function, stock tools
# (rsync + zip, both preinstalled on macOS). Produces a zip whose ROOT is the
# manifest.json (what the Web Store expects), with all dev cruft stripped.
#
# Usage:  ./scripts/package-extension.sh
# Output: dist/atelier-capture-<version>.zip
#
set -euo pipefail

# --- Paths -----------------------------------------------------------------
# Resolve locations relative to this script so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXTENSION_DIR="${REPO_ROOT}/extension"
DIST_DIR="${REPO_ROOT}/dist"
STAGE_DIR="${DIST_DIR}/.stage"

# --- Read the version from the manifest ------------------------------------
# Single source of truth: the zip name tracks the manifest version, so a bumped
# manifest yields a distinctly-named artifact (no accidental overwrite).
read_manifest_version() {
  # Grep the "version": "x.y.z" line; no jq dependency.
  grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "${EXTENSION_DIR}/manifest.json" \
    | head -1 \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

VERSION="$(read_manifest_version)"
if [[ -z "${VERSION}" ]]; then
  echo "error: could not read version from ${EXTENSION_DIR}/manifest.json" >&2
  exit 1
fi
ZIP_PATH="${DIST_DIR}/atelier-capture-${VERSION}.zip"

# --- Stage a clean copy ----------------------------------------------------
# rsync into a staging dir, excluding everything the store upload must not
# carry: OS junk, VCS, deps, source maps, and dev-only tooling/tests/config
# that the runtime extension never loads (the manifest references only src/*).
stage_clean_copy() {
  rm -rf "${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}"
  rsync -a \
    --exclude='.DS_Store' \
    --exclude='.git/' \
    --exclude='.gitignore' \
    --exclude='node_modules/' \
    --exclude='*.map' \
    --exclude='test/' \
    --exclude='scripts/' \
    --exclude='package.json' \
    --exclude='package-lock.json' \
    --exclude='README.md' \
    "${EXTENSION_DIR}/" "${STAGE_DIR}/"
}

# --- Zip it ----------------------------------------------------------------
# Zip the CONTENTS of the stage dir so manifest.json sits at the zip root
# (Chrome Web Store requirement). -X drops extra file attributes; a fresh
# rm keeps re-runs deterministic.
build_zip() {
  rm -f "${ZIP_PATH}"
  ( cd "${STAGE_DIR}" && zip -r -X -q "${ZIP_PATH}" . )
}

# --- Run -------------------------------------------------------------------
mkdir -p "${DIST_DIR}"
stage_clean_copy
build_zip
rm -rf "${STAGE_DIR}"

SIZE="$(du -h "${ZIP_PATH}" | cut -f1 | tr -d '[:space:]')"
echo "Packaged Atelier Capture v${VERSION}"
echo "  -> ${ZIP_PATH} (${SIZE})"
echo "Contents (top level):"
unzip -l "${ZIP_PATH}" | awk 'NR>3 && $4 !~ /\// {print "  " $4}' | grep -vE '^\s*$' || true
