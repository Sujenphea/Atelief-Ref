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
#   ./scripts/verify.sh ui      the macOS UI smoke suite (099 · P2) ALONE.
#                               Deliberately NOT part of `full` — see below.
#
# **Why the UI suite is not in the gate** (099 · issue 23, the user's call).
# `AtelierRefsUITests` is real and it works; what does not work is running it
# unattended. Its runner must be signed AD-HOC — an unsigned XCTest runner is
# SIGKILLed before it connects — and an ad-hoc signature has no team, so its
# designated requirement collapses to the exact cdhash. Every rebuild is
# therefore a stranger to macOS, and the TCC automation grant and keychain ACL
# that the previous build earned do not carry over. The observed failures are
# `Test crashed with signal kill`, a 30 s main-thread block on a keychain prompt
# nothing can answer (fixed separately in 471), and finally an automation session
# that sets up and then sees NO WINDOWS in a demonstrably healthy app.
#
# None of that is a signal about the code, and a gate that reddens for reasons
# the code cannot fix is a gate people learn to re-run past — the exact road 464
# was written to get off. So it is out of `full` rather than warned-about: a UI
# failure that DID mean something would otherwise be indistinguishable.
#
# Run it by hand with `verify.sh ui` after granting the prompts, or wire it back
# into `full` once the runner signs with a stable identity (issue 23C).
# Exit code is non-zero if any stage fails; every stage runs regardless, so one
# failure does not hide the others (CI's `fail-fast: false`).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_FILE="${REPO_ROOT}/.github/workflows/ci.yml"
MODE="${1:-full}"

if [[ "${MODE}" != "fast" && "${MODE}" != "full" && "${MODE}" != "ui" ]]; then
    echo "usage: $0 [fast|full|ui]" >&2
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

# **The app target's tests run SERIALLY** (`-parallel-testing-enabled NO`), and
# that is a correctness requirement rather than a concession to flakiness.
#
# `AtelierRefsTests` is HOSTED IN THE APP: each runner process launches a real
# AtelierRefs, which boots `IngestionModel` and binds the capture endpoint on a
# FIXED port (`IngestionModel.capturePort()` — `CaptureServer.defaultPort`, or
# `+1` for a `.dev` bundle id). Two runner processes therefore race for one
# socket, and the loser logs
#
#     [FlyingFox] server error: SocketError. Bind(48): Address already in use
#
# …and runs on with `captureEndpointRunning == false`. They also share one
# sandbox container. Two hosts of this app are not independent, so running two of
# them concurrently is unsound however green it happens to come out.
#
# It is also what the gate's remaining intermittent failure looks like: a flat
# `60.000 s` against a suite's one-minute `.timeLimit`, naming an arbitrary
# `@MainActor` test — twice a *synchronous* one, which cannot hang and can only
# fail to START, i.e. something else was holding the main actor. That is
# `.change-log/482`'s signature A, which 482 fixed for the cooperative pool (its
# bounded `DecodeLatch` is still the only blocking primitive in the target). The
# main-actor equivalent was never found: it did not reproduce in four serial
# attempts, under 2x-core CPU load, or with the capture port deliberately held.
# So this does NOT claim to have fixed it — it removes the concurrency the
# failures only ever appeared under, and makes the stage deterministic.
#
# The cost is ~45 s, measured: 46 s serial against ~90 s parallel.
app_target() {
    local action="build"
    local -a extra=()
    if [[ "${MODE}" == "full" ]]; then
        action="test"
        extra=(-only-testing:AtelierRefsTests -parallel-testing-enabled NO)
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

# 099 · P2 (decision 10A) — the macOS smoke target.
#
# **A second app stage, not a second `-only-testing` on the first.** A UI failure
# and a unit failure have nothing to do with each other: one means a window, a
# keystroke or an element identifier moved, the other means a value is wrong. One
# summary line covering both would tell a reader neither, and this gate's whole
# job is to say which thing broke.
#
# **It cannot take `CODE_SIGNING_ALLOWED=NO`**, which every other app stage here
# does. A UI-test bundle ships a RUNNER app whose executable is `lipo`-extracted
# from Xcode's `XCTRunner.app`, and an unsigned arm64 binary is killed by the
# kernel before it can connect: `Early unexpected exit … Test crashed with signal
# kill before establishing connection`, with no compile error and no test output
# to explain it. Ad-hoc (`CODE_SIGN_IDENTITY=-`) is the smallest signature that
# launches, needs no keychain identity and no provisioning profile, and still
# applies the app's entitlements — so the app under test is sandboxed exactly as
# it ships, which is what makes the fixture library's RELATIVE root
# (`ATELIER_LIBRARY_ROOT=uitest-fixture`, resolved inside the container) the same
# path in the test as in the wild. The cost is that this stage does not share
# build products with the two stages that sign differently.
#
# A plain `run_stage`: a UI failure is a real failure. The suite is scoped to
# smoke deliberately (099 · risks) — three flows, no layout assertions — because
# the thing being defended against is a Mac app that no longer launches, not a
# pixel.
app_ui_tests() {
    local log
    log="$(mktemp -t verify-app-ui)"
    local status=0
    xcodebuild test \
        -project "${REPO_ROOT}/AtelierRefs/AtelierRefs.xcodeproj" \
        -scheme AtelierRefs \
        -destination 'platform=macOS' \
        -only-testing:AtelierRefsUITests \
        -skipPackagePluginValidation \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_STYLE=Manual \
        PROVISIONING_PROFILE_SPECIFIER= \
        > "${log}" 2>&1 || status=$?

    grep -E "error:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Test Case .* failed" \
        "${log}" | tail -20
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

if [[ "${MODE}" == "ui" ]]; then
    # The UI suite alone, on purpose and by hand. See the header for why it is
    # not in `full`. Expect to answer a macOS permission prompt after a rebuild.
    printf '\033[1mverify.sh (ui) — the macOS smoke suite only\033[0m\n'
    run_stage "App target (UI)" app_ui_tests
else

printf '\033[1mverify.sh (%s) — %d packages from ci.yml\033[0m\n' \
    "${MODE}" "${#PACKAGES[@]}"

for pkg in "${PACKAGES[@]}"; do
    run_stage "${pkg}" swift_package "${pkg}"
done

run_stage "App target" app_target

# Release is a full-mode stage: a second whole-app compile, and `fast` is meant
# to stay in the seconds. The guards it checks are not the kind that change
# between one edit and the next.
if [[ "${MODE}" == "full" ]]; then
    run_stage "App target (Release)" app_release_build
fi

# The extension is node, not Swift — nothing to compile-check, so it is a
# full-mode stage only.
if [[ "${MODE}" == "full" ]]; then
    run_warnable_stage "Extension" extension_tests
fi

fi  # end non-ui modes

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
