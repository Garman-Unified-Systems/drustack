#!/usr/bin/env bash
# test-release-gate.sh — fixture tests for release-gate.sh.
#
# Each should-fail fixture must produce exit 1 from the gate.
# Each should-pass fixture must produce exit 0 from the gate.
# The history test verifies that a secret committed then deleted still fails.
#
# Usage:
#   ./tests/test-release-gate.sh
#
# Requires: gitleaks on PATH, git on PATH.
# Exit code: 0 all tests passed, 1 one or more tests failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATE="${REPO_ROOT}/scripts/release-gate.sh"
FAIL_DIR="${SCRIPT_DIR}/fixtures/should-fail"
PASS_DIR="${SCRIPT_DIR}/fixtures/should-pass"

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

run_gate_on_dir() {
    local dir="$1"
    local expected_exit="$2"
    local extra_args="${3:-}"

    local actual_exit=0
    # shellcheck disable=SC2086
    bash "${GATE}" ${extra_args} "${dir}" >/dev/null 2>&1 || actual_exit=$?

    if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
        printf "${GREEN}PASS${RESET} gate=%d expected=%d  %s\n" \
            "${actual_exit}" "${expected_exit}" "${dir}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "${RED}FAIL${RESET} gate=%d expected=%d  %s\n" \
            "${actual_exit}" "${expected_exit}" "${dir}"
        # shellcheck disable=SC2086
        bash "${GATE}" ${extra_args} "${dir}" || true
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "=== release-gate fixture tests ==="
echo

# Each fixture file is placed into its own named test directory.
# Named paths avoid variable-expansion issues with cleanup hooks.
TEST_BASE="/tmp/release-gate-tests"
mkdir -p "${TEST_BASE}"

echo "--- should-fail fixtures (expect exit 1) ---"
for fixture_file in "${FAIL_DIR}"/*; do
    [[ -f "${fixture_file}" ]] || continue
    fixture_name="$(basename "${fixture_file}")"
    test_dir="${TEST_BASE}/fail-${fixture_name}"
    mkdir -p "${test_dir}"
    /bin/cp -f "${fixture_file}" "${test_dir}/${fixture_name}"
    run_gate_on_dir "${test_dir}" 1
done

echo
echo "--- should-pass fixtures (expect exit 0) ---"
for fixture_file in "${PASS_DIR}"/*; do
    [[ -f "${fixture_file}" ]] || continue
    fixture_name="$(basename "${fixture_file}")"
    test_dir="${TEST_BASE}/pass-${fixture_name}"
    mkdir -p "${test_dir}"
    /bin/cp -f "${fixture_file}" "${test_dir}/${fixture_name}"
    run_gate_on_dir "${test_dir}" 0
done

echo
echo "--- history scan test (secret committed then deleted must fail) ---"
# Create a temporary git repo, commit a Notion token, delete it, verify gate
# still fails because the secret lives in git history.
HIST_DIR="${TEST_BASE}/history-scan-test-$$"
mkdir -p "${HIST_DIR}"

# Configure a minimal git identity so commits work in CI.
git -C "${HIST_DIR}" init -q
git -C "${HIST_DIR}" config user.email "test@example.com"
git -C "${HIST_DIR}" config user.name "Release Gate Test"

# Commit 1: add a file containing a fake Notion token.
# The token matches the notion-token rule: ntn_[0-9A-Za-z]{40,}
printf 'NOTION_SECRET=ntn_A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0U1V2\n' \
    > "${HIST_DIR}/secret-then-deleted.txt"
git -C "${HIST_DIR}" add secret-then-deleted.txt
git -C "${HIST_DIR}" commit -q -m "add config"

# Commit 2: delete the file — the secret is gone from the working tree.
git -C "${HIST_DIR}" rm -q secret-then-deleted.txt
git -C "${HIST_DIR}" commit -q -m "remove config"

# Working tree is now clean — filesystem scan should not find the secret.
# The history scan must still find it in the first commit.
printf "History scan test: working-tree clean, secret in history ...\n"
run_gate_on_dir "${HIST_DIR}" 1

echo
echo "=== results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

[[ "${FAIL_COUNT}" -eq 0 ]]
