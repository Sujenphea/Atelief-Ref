#!/usr/bin/env bash
#
# run-local.command — double-click to build the Release configuration and launch it.
#
# The companion to release.sh, for the case that script deliberately refuses to
# serve: running the production build on THIS machine, right now, without a
# Developer ID identity or a notarization round-trip. Same configuration, same
# hardened runtime, same sandbox entitlements — the signing identity differs, and
# with it one entitlement an unteamed signature forces: see relax_library_validation.
#
# Why a `.command` and not a `.sh`: Finder runs a `.command` in Terminal on
# double-click. That is the whole point of this file. It is otherwise an ordinary
# bash script and runs fine from a shell.
#
#   Finder : double-click scripts/run-local.command
#   Shell  : ./scripts/run-local.command
#
# Pipeline:
#   resolve signing identity -> xcodebuild (Release) -> relax library validation
#     (ad-hoc only) -> quit old instance -> install into /Applications
#     -> open the INSTALLED app
#
# Why it installs: launching straight out of build/local-release leaves whatever
# was hand-dragged into /Applications untouched, and that copy is what the Dock,
# Spotlight and every future double-click actually open. Two bundles, one bundle
# id, one sandbox container — indistinguishable once running, and the stale one
# reads as "the fix isn't there". The build the script just made is the one it
# puts where you launch from.
#
# Overridable via the environment, same spirit as release.sh:
#   SCHEME, CONFIGURATION, OUTPUT_DIR, FORCE_ADHOC=1 (skip Developer ID even if
#   one is installed), NO_LAUNCH=1 (build/install only, don't open the app),
#   INSTALL=0 (skip the install and run out of the build tree, as this script
#   used to), INSTALL_DIR=… (somewhere other than /Applications),
#   FORCE_INSTALL=1 (allow replacing a Developer-ID-signed install with an
#   ad-hoc build). NO_LAUNCH and INSTALL compose: INSTALL=1 NO_LAUNCH=1 installs
#   without opening.
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

# Where the build ends up living. Installing is the default because that is the
# only thing that makes a double-click on the Dock icon show today's code.
INSTALL="${INSTALL:-1}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED_PATH="${INSTALL_DIR}/${APP_NAME}.app"
# Escape hatch for the one refusal that is a judgement call rather than a fact:
# replacing a Developer-ID-signed install with an ad-hoc local build.
FORCE_INSTALL="${FORCE_INSTALL:-0}"
# Whatever we end up launching / reporting — the installed bundle, or the build
# tree when INSTALL=0.
TARGET_PATH="${APP_PATH}"

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
# Sets SIGN_ARGS, and SIGN_ADHOC=1 when it fell back — install_app needs to know,
# because replacing a signed bundle with an ad-hoc one is a downgrade the user
# should get a say in.
resolve_signing() {
  echo "==> Resolving signing identity"
  SIGN_ADHOC=0
  if [[ "${FORCE_ADHOC:-0}" != "1" ]] \
      && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "Developer ID Application"; then
    echo "    Developer ID Application found — building signed (as release.sh would)"
    SIGN_ARGS=()
    return 0
  fi

  SIGN_ADHOC=1

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

# --- Step 2b: make the ad-hoc build loadable -------------------------------
# The hardened runtime turns on Library Validation, which lets a process load a
# non-platform library only when that library carries the SAME Team ID as the
# process. An ad-hoc signature carries no team at all — so the app (no team) and
# Sparkle.framework (ad-hoc too, equally teamless) do not match, and dyld kills
# the process at launch, before main() ever runs:
#
#   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#   … not valid for use in process: mapping process and mapped file
#     (non-platform) have different Team IDs
#
# A Developer ID build never meets this: app and framework both come out signed
# L25247V6JG and the teams match. So the entitlement below is scoped to the
# ad-hoc fallback and to nothing else — the hardened runtime stays on and every
# sandbox entitlement is untouched; the only rule lifted is the team match an
# unteamed signature can never satisfy in the first place.
#
# Only the .app wrapper is re-signed. The nested signatures — Sparkle and its two
# XPC services — stay byte-for-byte as xcodebuild wrote them.
relax_library_validation() {
  [[ "${SIGN_ADHOC}" == "1" ]] || return 0
  echo "==> Disabling library validation (ad-hoc build)"

  local ents="${OUTPUT_DIR}/adhoc.entitlements"

  # Delete it first. `codesign -d --entitlements FILE` APPENDS to an existing
  # file rather than truncating it, and OUTPUT_DIR survives between runs — so on
  # the second run the file holds two concatenated plists, PlistBuddy reads only
  # the first (last run's, already carrying the key below) and fails the whole
  # script with "Entry Already Exists". Reading the stale copy would also undo
  # the point of reading off the built bundle at all.
  rm -f "${ents}"

  # Read the entitlements back off the BUILT BUNDLE, not off the .entitlements
  # source file: what xcodebuild signed has $(PRODUCT_BUNDLE_IDENTIFIER) already
  # substituted into the two Sparkle mach-lookup names. The source file still has
  # the literal $(…), and re-signing with those would cut the app off from its
  # own updater XPC services.
  if ! codesign -d --entitlements "${ents}" --xml "${APP_PATH}" 2>/dev/null; then
    echo "error: could not read the entitlements back from ${APP_PATH}" >&2
    exit 1
  fi
  # Delete-then-Add, because bare `Add` is not idempotent and this step runs on
  # a bundle that may ALREADY carry the key: an incremental build that re-links
  # nothing also re-signs nothing, so the app keeps the previous run's re-signed
  # entitlements. `Add` onto an existing key fails, and under `set -e` that ends
  # the script. Delete tolerates a missing key; Add then puts it back true.
  /usr/libexec/PlistBuddy \
    -c 'Delete :com.apple.security.cs.disable-library-validation' \
    "${ents}" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
    "${ents}" >/dev/null

  # --options runtime is not inherited across a re-sign; without it this would
  # quietly drop the hardened runtime the whole script exists to preserve.
  codesign --force --sign - --options runtime --entitlements "${ents}" "${APP_PATH}"
  echo "    re-signed ad-hoc with com.apple.security.cs.disable-library-validation"
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

# --- Step 4: install -------------------------------------------------------
# Read the bundle id out of an existing install. Empty when there is no bundle,
# no Info.plist, or an unreadable one — every one of which means "don't touch it".
installed_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${INSTALLED_PATH}/Contents/Info.plist" 2>/dev/null || true
}

# True when the bundle already installed is signed by a Developer ID identity —
# i.e. something that came out of release.sh, not out of here. Parsed from
# codesign's `Authority=` line, never from the file name. An unreadable or
# unsigned bundle answers "no": a parse failure must not manufacture a refusal.
installed_is_developer_id() {
  local desc
  desc="$(codesign -dvv "${INSTALLED_PATH}" 2>&1 || true)"
  grep -q '^Authority=Developer ID Application' <<<"${desc}" \
    && grep -q '^TeamIdentifier=[^[:space:]]' <<<"${desc}" \
    && ! grep -q '^TeamIdentifier=not set' <<<"${desc}"
}

# Put the build we just made where the user launches from. Everything here is a
# guard or a swap; the copy itself is two lines in the middle.
install_app() {
  echo "==> Installing to ${INSTALL_DIR}"

  # Check writability up front. Left to ditto, an unwritable /Applications
  # surfaces as a bare "Operation not permitted" from somewhere inside a copy,
  # with no hint of what to do about it.
  [[ -d "${INSTALL_DIR}" ]] || {
    echo "error: install directory does not exist: ${INSTALL_DIR}" >&2
    echo "       create it, or point INSTALL_DIR= somewhere that exists." >&2
    exit 1
  }
  [[ -w "${INSTALL_DIR}" ]] || {
    echo "error: no write permission on ${INSTALL_DIR}" >&2
    echo "       re-run with sudo, or install elsewhere:" >&2
    echo "         sudo \"${BASH_SOURCE[0]}\"" >&2
    echo "         INSTALL_DIR=\"\${HOME}/Applications\" \"${BASH_SOURCE[0]}\"" >&2
    exit 1
  }

  if [[ -e "${INSTALLED_PATH}" ]]; then
    # Somebody else's app can sit at our path — same product name, different
    # vendor. Identity is the bundle id; the name proves nothing. Refuse rather
    # than overwrite: there is no undoing an rm of an app we did not ship.
    local existing_id
    existing_id="$(installed_bundle_id)"
    if [[ "${existing_id}" != "${BUNDLE_ID}" ]]; then
      echo "error: ${INSTALLED_PATH} is not this app — refusing to replace it." >&2
      echo "       found bundle id : ${existing_id:-<unreadable>}" >&2
      echo "       expected        : ${BUNDLE_ID}" >&2
      echo "       Move it aside yourself, or set INSTALL_DIR= elsewhere." >&2
      exit 1
    fi

    # A signed, notarized install is somebody's deliberate choice; an ad-hoc
    # build silently stomping it is a downgrade they never asked for (and one
    # they cannot detect afterwards — same name, same id, same icon).
    if [[ "${SIGN_ADHOC}" == "1" && "${FORCE_INSTALL}" != "1" ]] \
        && installed_is_developer_id; then
      echo "error: ${INSTALLED_PATH} is signed with a Developer ID identity, and" >&2
      echo "       this build is ad-hoc — installing would downgrade its signing." >&2
      echo "       Re-run with FORCE_INSTALL=1 to replace it anyway, or with" >&2
      echo "       INSTALL=0 to run out of the build tree instead." >&2
      exit 1
    fi
  fi

  # Quit BEFORE the swap, not after: replacing a bundle's contents under a
  # running process is how you get a half-swapped app that crashes on the next
  # resource load. Runs in every installing path, launch or not.
  quit_running_instance

  # Stage inside INSTALL_DIR so the mv below is a same-volume rename — instant,
  # and with no second copy that can half-finish. ditto, not cp -R: it is the
  # copy that keeps the code signature, xattrs and symlinks inside a bundle intact.
  local staged="${INSTALL_DIR}/.${APP_NAME}.app.new.$$"
  local aside="${INSTALL_DIR}/.${APP_NAME}.app.old.$$"
  rm -rf "${staged}" "${aside}"
  if ! /usr/bin/ditto "${APP_PATH}" "${staged}"; then
    rm -rf "${staged}"
    echo "error: copying the app into ${INSTALL_DIR} failed." >&2
    echo "       Nothing was replaced — the previous install is untouched." >&2
    exit 1
  fi

  # Move the old one ASIDE rather than deleting it. rm-then-copy has a window in
  # which a failure leaves the user with no app at all; this one never does.
  local had_previous=0
  if [[ -e "${INSTALLED_PATH}" ]]; then
    if ! mv "${INSTALLED_PATH}" "${aside}"; then
      rm -rf "${staged}"
      echo "error: could not move the existing app aside; nothing was changed." >&2
      exit 1
    fi
    had_previous=1
  fi

  if ! mv "${staged}" "${INSTALLED_PATH}"; then
    # The only moment there is no app at the path. Put the old one back before
    # failing, so the worst case is "nothing happened", never "it's gone".
    if (( had_previous )); then
      mv "${aside}" "${INSTALLED_PATH}" || true
    fi
    rm -rf "${staged}"
    echo "error: could not move the new app into place." >&2
    echo "       The previous install was restored." >&2
    exit 1
  fi
  if (( had_previous )); then
    rm -rf "${aside}"
  fi

  # Gatekeeper's quarantine flag rides along on anything that has touched a
  # download or an archive, and on an ad-hoc bundle it turns first launch into a
  # "damaged app" dialog. A bundle carrying no such xattr is not an error.
  xattr -dr com.apple.quarantine "${INSTALLED_PATH}" >/dev/null 2>&1 || true

  # Point the Dock/Spotlight/`open -b` registration at the bundle we just wrote.
  # lsregister is a private tool at a long path — if a future macOS moves it,
  # that is not a reason to fail an otherwise-good install.
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks"
  lsregister="${lsregister}/LaunchServices.framework/Support/lsregister"
  if [[ -x "${lsregister}" ]]; then
    "${lsregister}" -f "${INSTALLED_PATH}" >/dev/null 2>&1 || true
  else
    echo "    (lsregister not found — skipped LaunchServices re-registration)"
  fi

  echo "    installed -> ${INSTALLED_PATH}"
}

# --- Step 5: launch --------------------------------------------------------
launch_app() {
  echo "==> Launching ${APP_NAME}"
  open "${TARGET_PATH}"
}

# --- Step 6: say what is actually there now --------------------------------
# The last lines of an install should be evidence, not a claim. Read the version
# and mtime back off disk, from the bundle now sitting at INSTALLED_PATH — that
# is the number Settings ▸ Diagnostics will show, and the answer to "is the Dock
# icon today's build".
report_installed() {
  local plist="${INSTALLED_PATH}/Contents/Info.plist"
  local short build modified
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${plist}" 2>/dev/null || echo '?')"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "${plist}" 2>/dev/null || echo '?')"
  # The .app DIRECTORY's mtime is not the build time — an incremental build that
  # only rewrites files inside it leaves the wrapper's own timestamp weeks old,
  # and ditto faithfully preserves that lie. The executable is what actually gets
  # relinked, so that is the timestamp worth printing.
  local stamped="${INSTALLED_PATH}/Contents/MacOS/${APP_NAME}"
  [[ -f "${stamped}" ]] || stamped="${INSTALLED_PATH}"
  modified="$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' \
    "${stamped}" 2>/dev/null || echo '?')"
  echo "Installed: ${INSTALLED_PATH}"
  echo "  version  : ${short} (${build})"
  echo "  modified : ${modified}"
}

# --- Orchestration ---------------------------------------------------------
main() {
  echo "AtelierRefs local build"
  echo "  project : ${PROJECT}"
  echo "  scheme  : ${SCHEME} (${CONFIGURATION})"
  if [[ "${INSTALL}" == "1" ]]; then
    echo "  install : ${INSTALLED_PATH}"
  else
    echo "  install : skipped (INSTALL=0 — running out of the build tree)"
  fi
  echo

  resolve_signing
  build_app
  relax_library_validation

  if [[ "${INSTALL}" == "1" ]]; then
    install_app
    TARGET_PATH="${INSTALLED_PATH}"
  fi

  if [[ "${NO_LAUNCH:-0}" == "1" ]]; then
    echo
    echo "Built (NO_LAUNCH=1, not launching): ${TARGET_PATH}"
  else
    # install_app already quit it, and did so before overwriting the bundle.
    # Only the INSTALL=0 path still needs the quit here.
    [[ "${INSTALL}" == "1" ]] || quit_running_instance
    launch_app
    echo
    echo "Running: ${TARGET_PATH}"
  fi

  if [[ "${INSTALL}" == "1" ]]; then
    report_installed
  fi
  return 0
}

main "$@"
