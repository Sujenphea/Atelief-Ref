#!/usr/bin/env bash
#
# release.sh — the Developer ID release lane for AtelierRefs (phase A2, decision 6A).
#
# Explicit over clever: stock tools only (xcodebuild / notarytool / stapler /
# create-dmg / Sparkle generate_appcast). No Fastlane, no Ruby. One step per
# function, sequenced by main(). Nothing secret lives here — the Developer ID
# cert, the notarytool keychain profile, and (later) the Sparkle EdDSA key all
# live in the login Keychain; see SECRETS.md for their locations.
#
# Pipeline:
#   resolve version -> archive -> export (developer-id) -> notarize --wait
#     -> staple -> create-dmg -> Sparkle generate_appcast (appcast.xml)
#
# Usage:
#   ./scripts/release.sh                 # marketing version from the project,
#                                        # build number from `git rev-list --count`
#   MARKETING_VERSION=1.2 CURRENT_PROJECT_VERSION=34 ./scripts/release.sh
#
# Distribution only — it deliberately does not install anything locally. To put a
# build where you launch from, use scripts/run-local.command.
#
# Override any of the env vars in the CONFIG block below to retarget output,
# scheme, team, or the notary profile. Requires a provisioned release machine
# (see SECRETS.md checklist); this script does NOT run in CI without those.
#
set -euo pipefail

# --- Paths -----------------------------------------------------------------
# Resolve locations relative to this script so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Config (all overridable via the environment) --------------------------
# Defaults are sourced from the committed, non-secret Release.xcconfig /
# ExportOptions.plist values (team ID L25247V6JG, scheme AtelierRefs).
PROJECT="${PROJECT:-${REPO_ROOT}/AtelierRefs/AtelierRefs.xcodeproj}"
SCHEME="${SCHEME:-AtelierRefs}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-AtelierRefs}"          # product name -> AtelierRefs.app
TEAM_ID="${TEAM_ID:-L25247V6JG}"             # public team id (Release.xcconfig)
NOTARY_PROFILE="${NOTARY_PROFILE:-AtelierRefs-notary}"  # keychain profile (SECRETS.md)
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-${REPO_ROOT}/AtelierRefs/Config/ExportOptions.plist}"

# Output layout (all under a single, overridable release dir).
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/build/release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${OUTPUT_DIR}/${APP_NAME}.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-${OUTPUT_DIR}/export}"
APP_PATH="${APP_PATH:-${EXPORT_DIR}/${APP_NAME}.app}"

# Sparkle tools (phase A3). Point SPARKLE_BIN_DIR at the directory that holds
# generate_appcast/sign_update. Sparkle is an SPM dependency (2.x), so `xcodebuild
# archive` unpacks its binary artifact under the project's DerivedData at:
#   ~/Library/Developer/Xcode/DerivedData/AtelierRefs-<hash>/SourcePackages/artifacts/sparkle/Sparkle/bin
# `resolve_sparkle_bin_dir` (below) auto-discovers that path after the archive
# step; export SPARKLE_BIN_DIR yourself to override (e.g. to a downloaded Sparkle
# release's Sparkle/bin). generate_appcast signs each update with the EdDSA
# private key in the login Keychain (see SECRETS.md).
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

# --- Version resolution ----------------------------------------------------
# The project uses GENERATE_INFOPLIST_FILE, so MARKETING_VERSION /
# CURRENT_PROJECT_VERSION are the build settings that matter. The environment
# still wins over everything below — that is the manual override for a re-cut of
# a version already published.
#
# MARKETING_VERSION comes from the project (the human decision).
# CURRENT_PROJECT_VERSION does NOT: pinned in the pbxproj it never moves, and a
# Sparkle appcast in which every entry claims build 1 has no way to order its
# updates. Derive it from `git rev-list --count HEAD` instead — monotonic on this
# branch, no state file to forget to bump, no version-bump commits. This is the
# release lane only; run-local.command keeps the project's pinned number, so a
# local build never invents a build number that was never published.
resolve_version() {
  echo "==> Resolving version/build"

  # A count only exists inside a repo with at least one commit; a tarball export
  # or a broken git has neither. Fall through to the build settings in that case
  # rather than failing a release over a version string.
  if [[ -z "${CURRENT_PROJECT_VERSION:-}" ]] && command -v git >/dev/null 2>&1; then
    local count
    # --count works on a shallow clone and on a detached HEAD; it just counts
    # what is actually present, which is exactly the property we want.
    count="$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || true)"
    if [[ "${count}" =~ ^[0-9]+$ && "${count}" != "0" ]]; then
      CURRENT_PROJECT_VERSION="${count}"
      echo "    build ${CURRENT_PROJECT_VERSION} (git rev-list --count HEAD)"
    fi
  fi

  if [[ -z "${MARKETING_VERSION:-}" || -z "${CURRENT_PROJECT_VERSION:-}" ]]; then
    # Ask xcodebuild for the effective settings (respects xcconfig + pbxproj).
    local settings
    settings="$(xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" \
      -configuration "${CONFIGURATION}" -showBuildSettings 2>/dev/null)"
    : "${MARKETING_VERSION:=$(awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}' <<<"${settings}")}"
    : "${CURRENT_PROJECT_VERSION:=$(awk -F' = ' '/ CURRENT_PROJECT_VERSION =/{print $2; exit}' <<<"${settings}")}"
  fi

  if [[ -z "${MARKETING_VERSION:-}" || -z "${CURRENT_PROJECT_VERSION:-}" ]]; then
    echo "error: could not resolve MARKETING_VERSION / CURRENT_PROJECT_VERSION." >&2
    echo "       pass them explicitly, e.g. MARKETING_VERSION=1.2 CURRENT_PROJECT_VERSION=34 $0" >&2
    exit 1
  fi

  VERSION_TAG="${MARKETING_VERSION}-${CURRENT_PROJECT_VERSION}"
  DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION_TAG}.dmg"
  ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION_TAG}.zip"
  echo "    version ${MARKETING_VERSION} (build ${CURRENT_PROJECT_VERSION}) -> ${VERSION_TAG}"
}

# --- Prerequisite checks ---------------------------------------------------
# Fail loudly and actionably if a required tool or credential is missing,
# rather than deep inside a build step.
require_tool() {
  # require_tool <cmd> <install hint>
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' not found on PATH." >&2
    [[ -n "${2:-}" ]] && echo "       ${2}" >&2
    exit 1
  fi
}

preflight() {
  echo "==> Preflight: tools + credentials"
  require_tool xcodebuild "Install Xcode 26 and its command-line tools."
  require_tool xcrun "Install Xcode command-line tools."

  # Developer ID signing identity must be present in the login keychain (5A).
  if ! security find-identity -v -p codesigning 2>/dev/null \
      | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' signing identity in the keychain." >&2
    echo "       Install the Developer ID cert + private key (see SECRETS.md)." >&2
    echo "       Verify: security find-identity -v -p codesigning" >&2
    exit 1
  fi

  # notarytool keychain profile must exist (SECRETS.md: AtelierRefs-notary).
  if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "error: notarytool profile '${NOTARY_PROFILE}' missing or not authorized." >&2
    echo "       Create it: xcrun notarytool store-credentials ${NOTARY_PROFILE}" >&2
    echo "       (see SECRETS.md for the App-Store-Connect key / Apple ID inputs)." >&2
    exit 1
  fi

  [[ -f "${EXPORT_OPTIONS_PLIST}" ]] || {
    echo "error: ExportOptions.plist not found at ${EXPORT_OPTIONS_PLIST}" >&2
    exit 1
  }
  echo "    ok"
}

# --- Step 1: archive -------------------------------------------------------
build_archive() {
  echo "==> Archiving ${SCHEME} (${CONFIGURATION}) -> ${ARCHIVE_PATH}"
  rm -rf "${ARCHIVE_PATH}"
  xcodebuild archive \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION}"
  echo "    archived -> ${ARCHIVE_PATH}"
}

# --- Step 2: export (Developer ID) -----------------------------------------
export_archive() {
  echo "==> Exporting (developer-id) -> ${EXPORT_DIR}"
  rm -rf "${EXPORT_DIR}"
  xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
    -exportPath "${EXPORT_DIR}"
  [[ -d "${APP_PATH}" ]] || {
    echo "error: expected exported app at ${APP_PATH}, not found." >&2
    echo "       exported contents:" >&2
    ls -la "${EXPORT_DIR}" >&2 || true
    exit 1
  }
  echo "    exported -> ${APP_PATH}"
}

# --- Step 3: notarize ------------------------------------------------------
# notarytool needs a zip (or dmg). Zip the .app, submit, wait for the verdict.
notarize_app() {
  echo "==> Notarizing ${APP_PATH} (profile ${NOTARY_PROFILE})"
  rm -f "${ZIP_PATH}"
  # ditto preserves the code signature inside the zip (do NOT use plain zip).
  /usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
  xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
  echo "    notarization accepted"
}

# --- Step 4: staple --------------------------------------------------------
# Staple the ticket onto the .app itself (not the zip), so the DMG built from it
# carries a stapled app that validates offline.
staple_app() {
  echo "==> Stapling notarization ticket -> ${APP_PATH}"
  xcrun stapler staple "${APP_PATH}"
  xcrun stapler validate "${APP_PATH}"
  echo "    stapled + validated"
}

# --- Step 5: create-dmg ----------------------------------------------------
# create-dmg is a third-party Homebrew tool, not part of Xcode.
build_dmg() {
  echo "==> Building DMG -> ${DMG_PATH}"
  require_tool create-dmg "Install it: brew install create-dmg"
  rm -f "${DMG_PATH}"
  # Stage the app alone so create-dmg's window only shows the app + Applications.
  local dmg_stage="${OUTPUT_DIR}/.dmg-stage"
  rm -rf "${dmg_stage}"
  mkdir -p "${dmg_stage}"
  /usr/bin/ditto "${APP_PATH}" "${dmg_stage}/${APP_NAME}.app"

  create-dmg \
    --volname "${APP_NAME} ${MARKETING_VERSION}" \
    --app-drop-link 480 170 \
    --icon "${APP_NAME}.app" 160 170 \
    --window-size 640 360 \
    "${DMG_PATH}" \
    "${dmg_stage}"
  rm -rf "${dmg_stage}"
  echo "    built -> ${DMG_PATH}"
}

# Locate Sparkle's bin dir. Prefer an explicit SPARKLE_BIN_DIR; otherwise resolve
# it from the SPM artifacts Xcode unpacked into the project's DerivedData during
# the archive step. Xcode names the DerivedData dir AtelierRefs-<hash>, so glob
# for the newest match. Sets SPARKLE_BIN_DIR on success; leaves it empty on miss.
resolve_sparkle_bin_dir() {
  [[ -n "${SPARKLE_BIN_DIR}" ]] && return 0
  local dd="${HOME}/Library/Developer/Xcode/DerivedData"
  local candidate
  # Newest matching SourcePackages artifacts dir first.
  candidate="$(/bin/ls -dt \
    "${dd}"/AtelierRefs-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    2>/dev/null | head -n 1 || true)"
  [[ -n "${candidate}" && -x "${candidate}/generate_appcast" ]] && SPARKLE_BIN_DIR="${candidate}"
}

# --- Step 6: Sparkle appcast ----------------------------------------------
# Sparkle's generate_appcast signs each update with the EdDSA private key from
# the login Keychain and (re)writes appcast.xml for every archive in OUTPUT_DIR
# (it reads SUFeedURL/SUPublicEDKey context from the app bundles it finds).
generate_appcast() {
  echo "==> Generating Sparkle appcast for ${OUTPUT_DIR}"
  resolve_sparkle_bin_dir

  local tool=""
  if [[ -n "${SPARKLE_BIN_DIR}" && -x "${SPARKLE_BIN_DIR}/generate_appcast" ]]; then
    tool="${SPARKLE_BIN_DIR}/generate_appcast"
  elif command -v generate_appcast >/dev/null 2>&1; then
    tool="$(command -v generate_appcast)"
  fi

  if [[ -z "${tool}" ]]; then
    echo "error: Sparkle 'generate_appcast' not found." >&2
    echo "       It ships with the Sparkle SPM dependency and is unpacked under:" >&2
    echo "         ~/Library/Developer/Xcode/DerivedData/AtelierRefs-<hash>/SourcePackages/artifacts/sparkle/Sparkle/bin" >&2
    echo "       Ensure the archive step resolved packages, or set SPARKLE_BIN_DIR" >&2
    echo "       to that dir (or a downloaded Sparkle release's Sparkle/bin)." >&2
    exit 1
  fi

  echo "    tool -> ${tool}"
  "${tool}" "${OUTPUT_DIR}"
  echo "    appcast -> ${OUTPUT_DIR}/appcast.xml"
}

# --- Orchestration ---------------------------------------------------------
main() {
  mkdir -p "${OUTPUT_DIR}"
  echo "AtelierRefs release lane"
  echo "  project : ${PROJECT}"
  echo "  scheme  : ${SCHEME} (${CONFIGURATION})"
  echo "  team    : ${TEAM_ID}"
  echo "  output  : ${OUTPUT_DIR}"
  echo

  resolve_version
  preflight
  build_archive
  export_archive
  notarize_app
  staple_app
  build_dmg
  generate_appcast

  echo
  echo "Release complete for ${APP_NAME} ${VERSION_TAG}"
  echo "  app     : ${APP_PATH}"
  echo "  dmg     : ${DMG_PATH}"
  echo "  appcast : ${OUTPUT_DIR}/appcast.xml"
  echo "Next: verify with ./scripts/verify-release.sh \"${APP_PATH}\" \"${DMG_PATH}\" \"${OUTPUT_DIR}/appcast.xml\""
}

main "$@"
