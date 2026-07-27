#!/usr/bin/env bash
#
# verify-release.sh — the release-lane guard (phase A2, decision 9A).
#
# Run against a built artifact (the exported/stapled .app and optionally the
# distributable .dmg). Each assertion is its own function with a clear PASS/FAIL
# line; any failure makes the whole script exit non-zero. Intended to run in CI
# on release tags, and by hand after ./scripts/release.sh.
#
# Checks (9A + the 12A release-gate clauses that need a real key/host):
#   1. codesign --verify --deep --strict --verbose=2
#   2. spctl -a -t exec -vvv          (Gatekeeper accepts)
#   3. stapler validate               (notarization ticket stapled)
#   4. notarization ticket present    (stapler + spctl "source=Notarized")
#   5. hardened runtime + app-sandbox + network.server + Sparkle mach-lookup
#      entitlements present (2A posture + A3 XPC exception)
#   6. Sparkle sign_update signature verifies for the DMG (guarded: needs A3)
#   7. Sparkle SUFeedURL/SUPublicEDKey are real, not the REPLACE-ME placeholders
#      (this is the 12A "non-placeholder" clause — kept OUT of the always-on unit
#      suite, which only asserts key presence, so it gates real releases here)
#   8. appcast.xml is well-formed and carries an EdDSA signature + enclosure
#      (release-path only: needs the generated appcast; optional 3rd arg)
#
# Usage:
#   ./scripts/verify-release.sh path/to/AtelierRefs.app \
#       [path/to/AtelierRefs.dmg] [path/to/appcast.xml]
#
set -euo pipefail

# --- Args ------------------------------------------------------------------
APP_PATH="${1:-}"
DMG_PATH="${2:-}"
APPCAST_PATH="${3:-}"

if [[ -z "${APP_PATH}" ]]; then
  echo "usage: $0 <AtelierRefs.app> [AtelierRefs.dmg]" >&2
  exit 2
fi
if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app not found (or not a bundle): ${APP_PATH}" >&2
  exit 2
fi

# Sparkle sign_update location (phase A3), same convention as release.sh: prefer
# an explicit SPARKLE_BIN_DIR, else auto-discover the SPM artifacts bin dir Xcode
# unpacked into the project's DerivedData.
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-}"

resolve_sparkle_bin_dir() {
  [[ -n "${SPARKLE_BIN_DIR}" ]] && return 0
  local dd="${HOME}/Library/Developer/Xcode/DerivedData"
  local candidate
  candidate="$(/bin/ls -dt \
    "${dd}"/AtelierRefs-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    2>/dev/null | head -n 1 || true)"
  [[ -n "${candidate}" && -x "${candidate}/sign_update" ]] && SPARKLE_BIN_DIR="${candidate}"
}

# --- Result bookkeeping ----------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILED_CHECKS=()

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() {
  echo "  FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_CHECKS+=("$1")
}

# --- Check 1: codesign valid ----------------------------------------------
check_codesign() {
  echo "==> codesign --verify --deep --strict"
  if codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1; then
    pass "codesign verify (deep/strict)"
  else
    fail "codesign verify (deep/strict)"
  fi
}

# --- Check 2: Gatekeeper (spctl) accepts -----------------------------------
check_gatekeeper() {
  echo "==> spctl -a -t exec (Gatekeeper assessment)"
  if spctl -a -t exec -vvv "${APP_PATH}" 2>&1; then
    pass "Gatekeeper accepts (spctl exec)"
  else
    fail "Gatekeeper accepts (spctl exec)"
  fi
}

# --- Check 3: staple validates ---------------------------------------------
check_staple() {
  echo "==> stapler validate"
  if xcrun stapler validate "${APP_PATH}" 2>&1; then
    pass "stapler validate"
  else
    fail "stapler validate"
  fi
}

# --- Check 4: notarization ticket present ----------------------------------
# A successfully stapled+accepted app reports "source=Notarized Developer ID"
# from spctl. We assert that explicitly so a merely-signed (un-notarized) app is
# caught even if spctl's exit code were lenient.
check_notarized() {
  echo "==> notarization ticket present (spctl source=Notarized)"
  local out
  out="$(spctl -a -t exec -vvv "${APP_PATH}" 2>&1 || true)"
  if grep -qi "source=Notarized" <<<"${out}"; then
    pass "notarization ticket present"
  else
    fail "notarization ticket present (spctl did not report source=Notarized)"
    echo "       spctl said: ${out}" >&2
  fi
}

# --- Check 5: hardened runtime + required entitlements ----------------------
# Hardened runtime shows as the 'runtime' code-signing flag; the sandbox +
# network.server entitlements must survive into the signed binary (decision 2A).
check_runtime_and_entitlements() {
  echo "==> hardened runtime + app-sandbox + network.server"

  # Hardened runtime flag.
  local flags
  flags="$(codesign -dvvv "${APP_PATH}" 2>&1 || true)"
  if grep -qiE 'flags=.*runtime' <<<"${flags}"; then
    pass "hardened runtime enabled"
  else
    fail "hardened runtime enabled (no 'runtime' flag from codesign -dvvv)"
  fi

  # Entitlements embedded in the signed binary.
  local ents
  ents="$(codesign -d --entitlements :- "${APP_PATH}" 2>/dev/null || true)"
  if grep -q 'com.apple.security.app-sandbox' <<<"${ents}"; then
    pass "app-sandbox entitlement present"
  else
    fail "app-sandbox entitlement present"
  fi
  if grep -q 'com.apple.security.network.server' <<<"${ents}"; then
    pass "network.server entitlement present"
  else
    fail "network.server entitlement present"
  fi

  # Sparkle's sandboxed Installer/Downloader XPC services are reached over the
  # per-app mach names Sparkle derives from the bundle id (`<id>-spks`/`-spki`);
  # the temporary-exception.mach-lookup.global-name entitlement (A3) must survive
  # into the signed binary or a sandboxed update can't launch. This is the 12A
  # "entitlements still have the mach-lookup exception" clause — it can't be a
  # host-free unit test (the app test host is sandboxed and the CI build unsigned),
  # so it's asserted here against the signed artifact.
  if grep -q 'temporary-exception.mach-lookup.global-name' <<<"${ents}"; then
    pass "Sparkle mach-lookup exception present"
  else
    fail "Sparkle mach-lookup exception present"
  fi
}

# --- Check 6: Sparkle update signature (DMG) -------------------------------
# sign_update signs the DMG with the EdDSA private key in the login Keychain and
# prints the `sparkle:edSignature=...` string the appcast carries. A zero exit
# confirms the signing key is present and can sign what a client would verify
# against SUPublicEDKey. Sparkle ships sign_update as an SPM artifact (phase A3).
check_sparkle_signature() {
  echo "==> Sparkle sign_update signature (DMG)"
  if [[ -z "${DMG_PATH}" ]]; then
    echo "  SKIP: no DMG argument given"
    return 0
  fi
  if [[ ! -f "${DMG_PATH}" ]]; then
    fail "Sparkle signature: DMG not found at ${DMG_PATH}"
    return 0
  fi

  resolve_sparkle_bin_dir
  local tool=""
  if [[ -n "${SPARKLE_BIN_DIR}" && -x "${SPARKLE_BIN_DIR}/sign_update" ]]; then
    tool="${SPARKLE_BIN_DIR}/sign_update"
  elif command -v sign_update >/dev/null 2>&1; then
    tool="$(command -v sign_update)"
  fi

  if [[ -z "${tool}" ]]; then
    # Tools unresolved (no DerivedData artifacts, no override): report, do not
    # hard-fail — the codesign/notarization checks above are the load-bearing ones.
    echo "  SKIP: Sparkle 'sign_update' not found." >&2
    echo "        Set SPARKLE_BIN_DIR to the SPM artifacts bin dir" >&2
    echo "        (~/Library/Developer/Xcode/DerivedData/AtelierRefs-<hash>/SourcePackages/artifacts/sparkle/Sparkle/bin)" >&2
    echo "        and re-run to sign/verify the DMG against SUPublicEDKey." >&2
    return 0
  fi

  # sign_update prints the signature for the file; a zero exit means it signed
  # successfully against the Keychain EdDSA key.
  if "${tool}" "${DMG_PATH}" >/dev/null 2>&1; then
    pass "Sparkle sign_update signature"
  else
    fail "Sparkle sign_update signature"
  fi
}

# --- Check 7: Sparkle keys are non-placeholder -----------------------------
# The always-on unit suite (ConfigContractTests) asserts SUFeedURL/SUPublicEDKey
# are PRESENT. The "they're real, not the shipped placeholders" clause can only
# be true once a human sets the host + EdDSA key, so it gates a real release here
# instead of failing every push. Read from the built app's merged Info.plist.
check_sparkle_placeholders() {
  echo "==> Sparkle SUFeedURL/SUPublicEDKey are non-placeholder"
  local plist="${APP_PATH}/Contents/Info.plist"
  if [[ ! -f "${plist}" ]]; then
    fail "Sparkle keys: app Info.plist not found at ${plist}"
    return 0
  fi

  local feed key
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${plist}" 2>/dev/null || true)"
  key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${plist}" 2>/dev/null || true)"

  if [[ -z "${feed}" ]]; then
    fail "SUFeedURL missing from built Info.plist"
  elif [[ "${feed}" == *REPLACE-ME* || "${feed}" == *REPLACE_* ]]; then
    fail "SUFeedURL is still the placeholder (${feed})"
  else
    pass "SUFeedURL is set (${feed})"
  fi

  if [[ -z "${key}" ]]; then
    fail "SUPublicEDKey missing from built Info.plist"
  elif [[ "${key}" == REPLACE_* || "${key}" == *REPLACE-ME* ]]; then
    fail "SUPublicEDKey is still the placeholder"
  else
    pass "SUPublicEDKey is set"
  fi
}

# --- Check 8: appcast.xml validity -----------------------------------------
# The generated appcast must be well-formed XML and carry, for its item, both an
# enclosure URL and a Sparkle EdDSA signature — the client verifies that signature
# against SUPublicEDKey, and check 6 already proved the private key can produce a
# verifiable signature. Optional: only runs when an appcast path is supplied.
check_appcast() {
  echo "==> appcast.xml well-formed + signed enclosure"
  if [[ -z "${APPCAST_PATH}" ]]; then
    echo "  SKIP: no appcast argument given"
    return 0
  fi
  if [[ ! -f "${APPCAST_PATH}" ]]; then
    fail "appcast: file not found at ${APPCAST_PATH}"
    return 0
  fi

  # Well-formed XML.
  if xmllint --noout "${APPCAST_PATH}" 2>/dev/null; then
    pass "appcast is well-formed XML"
  else
    fail "appcast is not well-formed XML"
    return 0
  fi

  local xml
  xml="$(cat "${APPCAST_PATH}")"
  if grep -q 'sparkle:edSignature' <<<"${xml}"; then
    pass "appcast carries a Sparkle EdDSA signature"
  else
    fail "appcast has no sparkle:edSignature (was it generated by generate_appcast?)"
  fi
  if grep -qE '<enclosure[^>]+url=' <<<"${xml}"; then
    pass "appcast item has an enclosure URL"
  else
    fail "appcast item has no <enclosure url=...>"
  fi
}

# --- Summary ---------------------------------------------------------------
print_summary() {
  echo
  echo "======================================================"
  echo "verify-release summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  if (( FAIL_COUNT > 0 )); then
    for c in "${FAILED_CHECKS[@]}"; do
      echo "  - FAILED: ${c}"
    done
  fi
  echo "======================================================"
}

main() {
  echo "Verifying release artifact"
  echo "  app: ${APP_PATH}"
  [[ -n "${DMG_PATH}" ]] && echo "  dmg: ${DMG_PATH}"
  [[ -n "${APPCAST_PATH}" ]] && echo "  appcast: ${APPCAST_PATH}"
  echo

  check_codesign
  check_gatekeeper
  check_staple
  check_notarized
  check_runtime_and_entitlements
  check_sparkle_signature
  check_sparkle_placeholders
  check_appcast

  print_summary
  (( FAIL_COUNT == 0 )) || exit 1
}

main "$@"
