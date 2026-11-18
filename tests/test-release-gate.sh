#!/usr/bin/env bash
# test-release-gate.sh — fixture tests for release-gate.sh.
#
# Each should-fail fixture must produce exit 1 from the gate.
# Each should-pass fixture must produce exit 0 from the gate.
#
# Usage:
#   ./tests/test-release-gate.sh
#
# Requires: gitleaks on PATH.
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

    local actual_exit=0
    bash "${GATE}" "${dir}" >/dev/null 2>&1 || actual_exit=$?

    if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
        printf "${GREEN}PASS${RESET} gate=%d expected=%d  %s\n" \
            "${actual_exit}" "${expected_exit}" "${dir}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "${RED}FAIL${RESET} gate=%d expected=%d  %s\n" \
            "${actual_exit}" "${expected_exit}" "${dir}"
        bash "${GATE}" "${dir}" || true
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
echo "=== results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

[[ "${FAIL_COUNT}" -eq 0 ]]
