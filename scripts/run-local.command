#!/usr/bin/env bash
#
# run-local.command — double-click to build the Release configuration and launch it.
#
# The companion to release.sh, for the case that script deliberately refuses to
# serve: running the production build on THIS machine, right now, without a
# Developer ID identity or a notarization round-trip. Same configuration, same
# hardened runtime, same sandbox entitlements — only the signing identity differs.
#
# Why a `.command` and not a `.sh`: Finder runs a `.command` in Terminal on
# double-click. That is the whole point of this file. It is otherwise an ordinary
# bash script and runs fine from a shell.
#
#   Finder : double-click scripts/run-local.command
#   Shell  : ./scripts/run-local.command
#
# Pipeline:
#   resolve signing identity -> xcodebuild (Release) -> quit old instance -> open
#
# Overridable via the environment, same spirit as release.sh:
#   SCHEME, CONFIGURATION, OUTPUT_DIR, FORCE_ADHOC=1 (skip Developer ID even if
#   one is installed), NO_LAUNCH=1 (build only, don't open the app).
#
set -euo pipefail

# --- Paths -----------------------------------------------------------------
# Finder launches a .command with the working directory set to $HOME, NOT the
# repo. Every path below therefore resolves from this script's own location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Config ----------------------------------------------------------------
PROJECT="${PROJECT:-${REPO_ROOT}/AtelierRefs/AtelierRefs.xcodeproj}"
SCHEME="${SCHEME:-AtelierRefs}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-AtelierRefs}"
BUNDLE_ID="${BUNDLE_ID:-sujenphea.AtelierRefs}"

# A derived-data path of its own, so this never fights Xcode's own build folder
# and never clobbers build/release (release.sh's output).
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/build/local-release}"
APP_PATH="${OUTPUT_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

# --- Keep the window readable ----------------------------------------------
# A double-clicked .command whose shell exits takes its output with it under the
# default Terminal profile. On any failure, hold the window open so the error is
# actually legible instead of a window that blinks out of existence.
hold_open_on_failure() {
  local code=$?
  [[ ${code} -eq 0 ]] && return 0
  echo
  echo "*** FAILED (exit ${code}) ***"
  echo "Scroll up for the first 'error:' line — that is the real one."
  # Only prompt when a human is actually looking at a terminal.
  if [[ -t 0 ]]; then
    echo
    read -r -n 1 -p "Press any key to close…"
    echo
  fi
}
trap hold_open_on_failure EXIT

# --- Step 1: resolve the signing identity ----------------------------------
# Release.xcconfig pins CODE_SIGN_IDENTITY = "Developer ID Application" (manual).
# On a provisioned release machine that is exactly right and we leave it alone.
# Everywhere else it is a hard build failure, so fall back to ad-hoc signing:
# the app still gets the hardened runtime and its full entitlement set, it simply
# isn't distributable. That is the correct trade for a local run.
#
# Sets SIGN_ARGS.
resolve_signing() {
  echo "==> Resolving signing identity"
  if [[ "${FORCE_ADHOC:-0}" != "1" ]] \
      && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "Developer ID Application"; then
    echo "    Developer ID Application found — building signed (as release.sh would)"
    SIGN_ARGS=()
    return 0
  fi

  if [[ "${FORCE_ADHOC:-0}" == "1" ]]; then
    echo "    FORCE_ADHOC=1 — signing ad-hoc by request"
  else
    echo "    no Developer ID identity in the keychain — signing ad-hoc"
  fi
  echo "    (runs locally; NOT distributable and will not pass verify-release.sh)"
  # DEVELOPMENT_TEAM must be cleared too: a team ID alongside an ad-hoc identity
  # sends xcodebuild looking for a provisioning profile that does not exist.
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="-"
    CODE_SIGN_STYLE=Manual
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGNING_ALLOWED=YES
    DEVELOPMENT_TEAM=""
  )
}

# --- Step 2: build ---------------------------------------------------------
# Incremental by design — xcodebuild reuses OUTPUT_DIR, so a second run after a
# one-file edit is seconds, not minutes. Delete build/local-release for a clean one.
build_app() {
  echo "==> Building ${SCHEME} (${CONFIGURATION})"
  echo "    output -> ${OUTPUT_DIR}"
  # -quiet keeps the click-to-run output to warnings and errors. Errors are never
  # suppressed by it.
  xcodebuild build \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${OUTPUT_DIR}" \
    -skipPackagePluginValidation \
    -quiet \
    "${SIGN_ARGS[@]}"

  [[ -d "${APP_PATH}" ]] || {
    echo "error: build reported success but no app at ${APP_PATH}" >&2
    exit 1
  }
  echo "    built -> ${APP_PATH}"
}

# --- Step 3: quit the previous instance ------------------------------------
# `open` on an already-running app just brings it forward — you would be staring
# at the BUILD YOU JUST REPLACED and wondering why the fix isn't there. Quit it
# first. Addressed by bundle id, never by pkill on a name: this repo's paths all
# contain "AtelierRefs", and a pattern kill would take unrelated processes with it.
quit_running_instance() {
  osascript -e "quit app id \"${BUNDLE_ID}\"" >/dev/null 2>&1 || true
  # Give the app a moment to actually go away before relaunching it.
  local waited=0
  while pgrep -qx "${APP_NAME}" && (( waited < 50 )); do
    /bin/sleep 0.1
    (( waited++ ))
  done
  (( waited > 0 )) && echo "==> Quit the running instance"
  return 0
}

# --- Step 4: launch --------------------------------------------------------
launch_app() {
  echo "==> Launching ${APP_NAME}"
  open "${APP_PATH}"
}

# --- Orchestration ---------------------------------------------------------
main() {
  echo "AtelierRefs local build"
  echo "  project : ${PROJECT}"
  echo "  scheme  : ${SCHEME} (${CONFIGURATION})"
  echo

  resolve_signing
  build_app

  if [[ "${NO_LAUNCH:-0}" == "1" ]]; then
    echo
    echo "Built (NO_LAUNCH=1, not launching): ${APP_PATH}"
    return 0
  fi

  quit_running_instance
  launch_app

  echo
  echo "Running: ${APP_PATH}"
}

main "$@"
