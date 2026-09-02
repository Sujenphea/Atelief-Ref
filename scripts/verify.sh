#!/usr/bin/env bash
#
# verify.sh — run locally what CI runs, so "it builds on my machine" and "it
# passes the gate" are the same sentence.
#
# This exists because they were not. The archive shelf made
# `collectionItems(in:sort:includeArchived:)` non-defaulted and updated every
# call site — except AtelierIngestion's tests, whose target then stopped
# compiling. It merged anyway, because verification was done by hand against
# whichever packages came to mind. `.github/workflows/ci.yml` would have caught
# it on the first push; nothing had been pushed in 32 commits.
#
# THE PACKAGE LIST IS PARSED OUT OF ci.yml. Do not copy it here. A second list is
# how the original bug happened: two places to update, one of them updated.
#
# Modes:
#   ./scripts/verify.sh fast    compile everything, including test targets.
#                               Seconds. Catches the class of break above.
#   ./scripts/verify.sh         the full CI matrix: package tests, the
#                               extension's node tests + drift check, the app's
#                               build-and-test, and a Release BUILD of the app
#                               (099 · 8A — the only stage that compiles the
#                               `#if DEBUG` guards' other side).
#
# Exit code is non-zero if any stage fails; every stage runs regardless, so one
# failure does not hide the others (CI's `fail-fast: false`).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_FILE="${REPO_ROOT}/.github/workflows/ci.yml"
MODE="${1:-full}"

if [[ "${MODE}" != "fast" && "${MODE}" != "full" ]]; then
    echo "usage: $0 [fast|full]" >&2
    exit 2
fi

# --- The package list, from CI ---------------------------------------------

if [[ ! -f "${CI_FILE}" ]]; then
    echo "error: cannot find ${CI_FILE} — the package list lives there" >&2
    exit 2
fi

# Matches the matrix line: `package: [AtelierCore, AtelierIngestion, ...]`.
# Fails loudly rather than silently testing nothing if the format changes.
PACKAGES_RAW="$(grep -E '^[[:space:]]*package:[[:space:]]*\[' "${CI_FILE}" \
    | head -1 | sed -E 's/^[^[]*\[//; s/\].*$//')"

if [[ -z "${PACKAGES_RAW}" ]]; then
    echo "error: could not parse the package matrix from ${CI_FILE}." >&2
    echo "       Expected a line like: package: [AtelierCore, AtelierIngestion]" >&2
    exit 2
fi

IFS=',' read -ra PACKAGES <<< "${PACKAGES_RAW}"
for i in "${!PACKAGES[@]}"; do
    PACKAGES[$i]="$(echo "${PACKAGES[$i]}" | tr -d '[:space:]')"
done

# --- Reporting --------------------------------------------------------------

FAILED=()
PASSED=()
WARNED=()

# A stage that exits with this code has NOT failed: it found something a reader
# should see that no code change can clear (today: a drift fixture past its
# staleness window, which only a fresh live capture fixes). Opt-in per stage via
# `run_warnable_stage` — a plain `run_stage` still treats every non-zero exit as
# a failure, so a genuine error can never be downgraded into a warning by a tool
# that happens to exit 2.
readonly WARN_STATUS=2

run_stage() {
    local name="$1"; shift
    printf '\n\033[1m▶ %s\033[0m\n' "${name}"
    if "$@"; then
        PASSED+=("${name}")
    else
        FAILED+=("${name}")
        printf '\033[31m✗ %s FAILED\033[0m\n' "${name}"
    fi
}

run_warnable_stage() {
    local name="$1"; shift
    printf '\n\033[1m▶ %s\033[0m\n' "${name}"
    local status=0
    "$@" || status=$?
    if [[ ${status} -eq 0 ]]; then
        PASSED+=("${name}")
    elif [[ ${status} -eq ${WARN_STATUS} ]]; then
        WARNED+=("${name}")
        printf '\033[33m⚠ %s — warning, not a failure\033[0m\n' "${name}"
    else
        FAILED+=("${name}")
        printf '\033[31m✗ %s FAILED\033[0m\n' "${name}"
    fi
}

# --- Stages -----------------------------------------------------------------

swift_package() {
    local pkg="$1"
    if [[ "${MODE}" == "fast" ]]; then
        # `--build-tests` is the point: a test target that no longer compiles is
        # invisible to a plain `swift build`, and that is exactly what shipped.
        (cd "${REPO_ROOT}/${pkg}" && swift build --build-tests)
    else
        (cd "${REPO_ROOT}/${pkg}" && swift test --parallel)
    fi
}

app_target() {
    local action="build"
    local -a extra=()
    if [[ "${MODE}" == "full" ]]; then
        action="test"
        extra=(-only-testing:AtelierRefsTests)
    fi

    # Log to a file and grep the FILE, rather than piping xcodebuild through
    # grep. Piping needs `PIPESTATUS` to recover the real exit code, and the
    # trailing `head` closes the pipe early — which is how the first version of
    # this function reported a green app target as a failure.
    local log
    log="$(mktemp -t verify-app)"
    local status=0
    xcodebuild "${action}" \
        -project "${REPO_ROOT}/AtelierRefs/AtelierRefs.xcodeproj" \
        -scheme AtelierRefs \
        -destination 'platform=macOS' \
        ${extra[@]+"${extra[@]}"} \
        -skipPackagePluginValidation \
        CODE_SIGNING_ALLOWED=NO \
        > "${log}" 2>&1 || status=$?

    grep -E "error:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)" "${log}" \
        | tail -20
    [[ ${status} -ne 0 ]] && echo "  (full log: ${log})"
    return ${status}
}

# 099 · 8A. `Debug/`, `CanvasRenderer/Spike/` and `-library-root` are now behind
# `#if DEBUG`, and a `#if DEBUG` guard is only ever checked by a build that does
# NOT define DEBUG. Every other stage here — `swift test`, the app's own
# build-and-test — is a debug build, so before this stage the entire Release side
# of those guards was unparsed: a type referenced from production code but
# declared inside `#if DEBUG` compiles green all day and fails at the one build
# nobody runs, which is the one that ships.
#
# A plain `run_stage`, not `run_warnable_stage`: a Release build failure is a
# real failure. Build only, never test — the test targets are debug-configured
# and there is nothing here to run; what is being checked is that the app's
# sources still form a program without DEBUG.
app_release_build() {
    local log
    log="$(mktemp -t verify-app-release)"
    local status=0
    xcodebuild build \
        -project "${REPO_ROOT}/AtelierRefs/AtelierRefs.xcodeproj" \
        -scheme AtelierRefs \
        -configuration Release \
        -destination 'platform=macOS' \
        -skipPackagePluginValidation \
        CODE_SIGNING_ALLOWED=NO \
        > "${log}" 2>&1 || status=$?

    grep -E "error:|BUILD (SUCCEEDED|FAILED)" "${log}" | tail -20
    [[ ${status} -ne 0 ]] && echo "  (full log: ${log})"
    return ${status}
}

extension_tests() {
    # The node suite is a hard failure, always. drift-check separates its arms:
    # 1 is real drift (a parser disagrees with a fixture, or the host tables
    # disagree) and 2 is only a stale fixture. Its code is passed through
    # untouched so the summary can tell those apart — see WARN_STATUS.
    (
        cd "${REPO_ROOT}/extension" || exit 1
        node --test || exit 1
        npm run drift-check
    )
}

# --- Run --------------------------------------------------------------------

printf '\033[1mverify.sh (%s) — %d packages from ci.yml\033[0m\n' \
    "${MODE}" "${#PACKAGES[@]}"

for pkg in "${PACKAGES[@]}"; do
    run_stage "${pkg}" swift_package "${pkg}"
done

run_stage "App target" app_target

# Release is a full-mode stage: it is a second whole-app compile, and `fast` is
# meant to stay in the seconds. The guards it checks are not the kind that change
# between one edit and the next.
if [[ "${MODE}" == "full" ]]; then
    run_stage "App target (Release)" app_release_build
fi

# The extension is node, not Swift — nothing to compile-check, so it is a
# full-mode stage only.
if [[ "${MODE}" == "full" ]]; then
    run_warnable_stage "Extension" extension_tests
fi

# --- Summary ----------------------------------------------------------------

printf '\n\033[1m── summary ──\033[0m\n'
# `${arr[@]}` on an EMPTY array is an unbound-variable error under `set -u` in
# bash 3.2, which is what macOS ships — and the empty case here is the all-passed
# case, so the naive form fails only on success. Hence the `+` expansions.
for name in ${PASSED[@]+"${PASSED[@]}"}; do printf '\033[32m  ✓ %s\033[0m\n' "${name}"; done
for name in ${WARNED[@]+"${WARNED[@]}"}; do printf '\033[33m  ⚠ %s\033[0m\n' "${name}"; done
for name in ${FAILED[@]+"${FAILED[@]}"}; do printf '\033[31m  ✗ %s\033[0m\n' "${name}"; done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    printf '\n\033[31m%d stage(s) failed.\033[0m\n' "${#FAILED[@]}"
    exit 1
fi
if [[ ${#WARNED[@]} -gt 0 ]]; then
    printf '\n\033[32mAll %d stages passed\033[0m\033[33m, %d with a warning above.\033[0m\n' \
        "$(( ${#PASSED[@]} + ${#WARNED[@]} ))" "${#WARNED[@]}"
    exit 0
fi
printf '\n\033[32mAll %d stages passed.\033[0m\n' "${#PASSED[@]}"
