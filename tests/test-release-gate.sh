#!/usr/bin/env bash
# test-release-gate.sh — fixture tests for release-gate.sh.
#
# Tests:
#   - should-fail fixtures: each must produce exit 1.
#   - should-pass fixtures: each must produce exit 0.
#   - Structural probes (from adversarial review): directory-structure, archive,
#     binary, UTF-16, URL-encoded paths, Windows paths, allowlist bypass cases,
#     git history (commit messages, deleted blobs).
#
# Denylist: uses RELEASE_GATE_DENYLIST_FILE pointing to the public example
# list so the codename check can run without a real secret.
#
# Usage: ./tests/test-release-gate.sh
# Requires: gitleaks on PATH, git on PATH, python3, zip (for archive test).
# Exit: 0 all passed, 1 one or more failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATE="${REPO_ROOT}/scripts/release-gate.sh"
FAIL_DIR="${SCRIPT_DIR}/fixtures/should-fail"
PASS_DIR="${SCRIPT_DIR}/fixtures/should-pass"
EXAMPLE_DENYLIST="${REPO_ROOT}/scripts/example-denylist.txt"

export RELEASE_GATE_DENYLIST_FILE="${EXAMPLE_DENYLIST}"

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

run_gate() {
    local dir="$1"
    local expected_exit="$2"
    local label="${3:-${dir}}"
    local extra_args="${4:-}"

    local actual_exit=0
    # shellcheck disable=SC2086
    bash "${GATE}" ${extra_args} "${dir}" >/dev/null 2>&1 || actual_exit=$?

    if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
        printf "${GREEN}PASS${RESET} gate=%d expected=%d  %s\n" \
            "${actual_exit}" "${expected_exit}" "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "${RED}FAIL${RESET} gate=%d expected=%d  %s\n" \
            "${actual_exit}" "${expected_exit}" "${label}"
        # shellcheck disable=SC2086
        bash "${GATE}" ${extra_args} "${dir}" || true
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "=== release-gate fixture tests ==="
echo

TEST_BASE="/tmp/release-gate-tests"
mkdir -p "${TEST_BASE}"

# ---------------------------------------------------------------------------
# 1. Standard should-fail fixtures
# ---------------------------------------------------------------------------
echo "--- should-fail fixtures (expect exit 1) ---"
for fixture_file in "${FAIL_DIR}"/*; do
    [[ -f "${fixture_file}" ]] || continue
    fixture_name="$(basename "${fixture_file}")"
    test_dir="${TEST_BASE}/fail-${fixture_name}"
    mkdir -p "${test_dir}"
    /bin/cp -f "${fixture_file}" "${test_dir}/${fixture_name}"
    run_gate "${test_dir}" 1 "fail/${fixture_name}"
done

# ---------------------------------------------------------------------------
# 2. Standard should-pass fixtures
# ---------------------------------------------------------------------------
echo
echo "--- should-pass fixtures (expect exit 0) ---"
for fixture_file in "${PASS_DIR}"/*; do
    [[ -f "${fixture_file}" ]] || continue
    fixture_name="$(basename "${fixture_file}")"
    test_dir="${TEST_BASE}/pass-${fixture_name}"
    mkdir -p "${test_dir}"
    /bin/cp -f "${fixture_file}" "${test_dir}/${fixture_name}"
    run_gate "${test_dir}" 0 "pass/${fixture_name}"
done

# ---------------------------------------------------------------------------
# 3. Allowlist bypass probes (s12, s13, s14 from adversarial review)
# A file at docs/tests/fixtures/should-fail/notes.txt must NOT be excluded
# because the gitleaks allowlist is anchored to ^tests/fixtures/should-fail/.
# A file named scripts/release-gate.sh.bak must NOT be excluded.
# A file at vendor/scripts/release-gate.sh-notes.md must NOT be excluded.
# ---------------------------------------------------------------------------
echo
echo "--- allowlist bypass probes (expect exit 1) ---"

# s12: subdirectory that looks like the excluded path but is not at repo root
AL_S12="${TEST_BASE}/allowlist-s12-$$"
mkdir -p "${AL_S12}/docs/tests/fixtures/should-fail"
printf 'token = "ntn_%s"\n' "$(python3 -c "import string,random; r=random.Random(7); print(''.join(r.choice(string.ascii_letters+string.digits) for _ in range(46)))")" \
    > "${AL_S12}/docs/tests/fixtures/should-fail/notes.txt"
run_gate "${AL_S12}" 1 "allowlist-bypass-s12-subdir"

# s13: .bak file next to the scanner script name
AL_S13="${TEST_BASE}/allowlist-s13-$$"
mkdir -p "${AL_S13}/scripts"
printf 'token = "ntn_%s"\n' "$(python3 -c "import string,random; r=random.Random(8); print(''.join(r.choice(string.ascii_letters+string.digits) for _ in range(46)))")" \
    > "${AL_S13}/scripts/release-gate.sh.bak"
run_gate "${AL_S13}" 1 "allowlist-bypass-s13-bak-file"

# s14: vendor/scripts/ path with fake denylist name + home path
AL_S14="${TEST_BASE}/allowlist-s14-$$"
mkdir -p "${AL_S14}/vendor/scripts"
printf 'FAKENODE-ALPHA runs PAM, see /Users/testuser/x\n' \
    > "${AL_S14}/vendor/scripts/release-gate.sh-notes.md"
run_gate "${AL_S14}" 1 "allowlist-bypass-s14-vendor-path"

# ---------------------------------------------------------------------------
# 4. Git history probes — secret/homepath/codename committed then deleted
# ---------------------------------------------------------------------------
echo
echo "--- git history probes (expect exit 1 — content in history only) ---"

make_git_repo() {
    local path="$1"
    mkdir -p "${path}"
    git -C "${path}" init -q
    git -C "${path}" config user.email "test@example.com"
    git -C "${path}" config user.name "Release Gate Test"
}

# s11: secret committed then deleted
HIST_S11="${TEST_BASE}/hist-s11-$$"
make_git_repo "${HIST_S11}"
printf 'token = "ntn_%s"\n' "$(python3 -c "import string,random; r=random.Random(1); print(''.join(r.choice(string.ascii_letters+string.digits) for _ in range(46)))")" \
    > "${HIST_S11}/f"
git -C "${HIST_S11}" add f && git -C "${HIST_S11}" commit -q -m "add"
git -C "${HIST_S11}" rm -q f && git -C "${HIST_S11}" commit -q -m "del"
run_gate "${HIST_S11}" 1 "hist-s11-secret-deleted"

# h07: homepath committed then deleted
HIST_H07="${TEST_BASE}/hist-h07-$$"
make_git_repo "${HIST_H07}"
printf '/Users/testuser/projects/config.json\n' > "${HIST_H07}/f"
git -C "${HIST_H07}" add f && git -C "${HIST_H07}" commit -q -m "add"
git -C "${HIST_H07}" rm -q f && git -C "${HIST_H07}" commit -q -m "del"
run_gate "${HIST_H07}" 1 "hist-h07-homepath-deleted"

# c14: denylist name committed then deleted
HIST_C14="${TEST_BASE}/hist-c14-$$"
make_git_repo "${HIST_C14}"
printf 'FAKENODE-ALPHA on FAKEBUS-ECHO\n' > "${HIST_C14}/f"
git -C "${HIST_C14}" add f && git -C "${HIST_C14}" commit -q -m "add"
git -C "${HIST_C14}" rm -q f && git -C "${HIST_C14}" commit -q -m "del"
run_gate "${HIST_C14}" 1 "hist-c14-codename-deleted"

# s10: secret in a commit message (not in any file)
HIST_S10="${TEST_BASE}/hist-s10-$$"
make_git_repo "${HIST_S10}"
printf 'placeholder\n' > "${HIST_S10}/f"
git -C "${HIST_S10}" add f
git -C "${HIST_S10}" commit -q -m "$(python3 -c "import string,random; r=random.Random(2); tok='ntn_'+''.join(r.choice(string.ascii_letters+string.digits) for _ in range(46)); print('rotate token = '+repr(tok))")"
run_gate "${HIST_S10}" 1 "hist-s10-secret-in-commit-msg"

# h06: home path in a commit message
HIST_H06="${TEST_BASE}/hist-h06-$$"
make_git_repo "${HIST_H06}"
printf 'placeholder\n' > "${HIST_H06}/f"
git -C "${HIST_H06}" add f && git -C "${HIST_H06}" commit -q -m "moved from /Users/testuser/DEV"
run_gate "${HIST_H06}" 1 "hist-h06-homepath-in-commit-msg"

# c13: codename in a commit message
HIST_C13="${TEST_BASE}/hist-c13-$$"
make_git_repo "${HIST_C13}"
printf 'placeholder\n' > "${HIST_C13}/f"
git -C "${HIST_C13}" add f && git -C "${HIST_C13}" commit -q -m "fix FAKENODE-ALPHA via FAKEBUS-ECHO"
run_gate "${HIST_C13}" 1 "hist-c13-codename-in-commit-msg"

# ---------------------------------------------------------------------------
# 5. UTF-16 probes (h08: home path in UTF-16 file)
# ---------------------------------------------------------------------------
echo
echo "--- encoding probes (expect exit 1) ---"

ENC_H08="${TEST_BASE}/enc-h08-$$"
mkdir -p "${ENC_H08}"
python3 -c "
import pathlib
p = pathlib.Path('${ENC_H08}/u.txt')
p.write_bytes('/Users/testuser/x\n'.encode('utf-16'))
"
run_gate "${ENC_H08}" 1 "enc-h08-utf16-homepath"

# s09: secret in UTF-16 file
ENC_S09="${TEST_BASE}/enc-s09-$$"
mkdir -p "${ENC_S09}"
python3 -c "
import pathlib, string, random
r = random.Random(3)
tok = 'ntn_' + ''.join(r.choice(string.ascii_letters+string.digits) for _ in range(46))
p = pathlib.Path('${ENC_S09}/u.txt')
p.write_bytes(('token = \"' + tok + '\"\n').encode('utf-16'))
"
run_gate "${ENC_S09}" 1 "enc-s09-utf16-secret"

# ---------------------------------------------------------------------------
# 6. Structural pattern probes (GOV-NNN, tailnet IP — no denylist needed)
# ---------------------------------------------------------------------------
echo
echo "--- structural pattern probes (expect exit 1) ---"

# c10: GOV-123 governance rule reference
STRUC="${TEST_BASE}/struc-gov123-$$"
mkdir -p "${STRUC}"
printf 'see GOV-123 for the rationale\n' > "${STRUC}/p.txt"
run_gate "${STRUC}" 1 "struc-c10-GOV-123"

# c11: gov-123 lowercase
STRUC="${TEST_BASE}/struc-gov123-lower-$$"
mkdir -p "${STRUC}"
printf 'see gov-123 for the rationale\n' > "${STRUC}/p.txt"
run_gate "${STRUC}" 1 "struc-c11-gov-123-lower"

# c12: GOV-12 (two-digit)
STRUC="${TEST_BASE}/struc-gov12-$$"
mkdir -p "${STRUC}"
printf 'see GOV-12 for the rationale\n' > "${STRUC}/p.txt"
run_gate "${STRUC}" 1 "struc-c12-GOV-12"

# c18: tailnet CGNAT address
STRUC="${TEST_BASE}/struc-tailnet-$$"
mkdir -p "${STRUC}"
printf 'http://100.115.27.81:7370/board\n' > "${STRUC}/p.txt"
run_gate "${STRUC}" 1 "struc-c18-tailnet-ip"

# ---------------------------------------------------------------------------
# 7. Denylist mechanical probes (fake names; tests case/punctuation tolerance)
# ---------------------------------------------------------------------------
echo
echo "--- denylist mechanical probes (expect exit 1) ---"

# c01: exact case match
MECH="${TEST_BASE}/mech-exact-$$"
mkdir -p "${MECH}"
printf 'runs on FAKENODE-ALPHA\n' > "${MECH}/p.txt"
run_gate "${MECH}" 1 "mech-c01-denylist-exact"

# c02: title case (IGNORECASE)
MECH="${TEST_BASE}/mech-titlecase-$$"
mkdir -p "${MECH}"
printf 'runs on Fakenode-Alpha\n' > "${MECH}/p.txt"
run_gate "${MECH}" 1 "mech-c02-denylist-titlecase"

# c06: lowercase match (IGNORECASE)
MECH="${TEST_BASE}/mech-lower-$$"
mkdir -p "${MECH}"
printf 'runs on fakenode-alpha\n' > "${MECH}/p.txt"
run_gate "${MECH}" 1 "mech-c06-denylist-lowercase"

# c05: short name from denylist in context
MECH="${TEST_BASE}/mech-short-$$"
mkdir -p "${MECH}"
printf 'the FAKEBUS-ECHO node\n' > "${MECH}/p.txt"
run_gate "${MECH}" 1 "mech-c05-denylist-in-prose"

# ---------------------------------------------------------------------------
# 8. False positive should-pass probes (already added as fixture files above)
# These are run again here as explicit probe labels for clarity.
# ---------------------------------------------------------------------------
echo
echo "--- false positive probes (expect exit 0) ---"

FP="${TEST_BASE}/fp-prism-$$"
mkdir -p "${FP}"
printf 'Syntax highlighting via Prism.js\n' > "${FP}/p.txt"
run_gate "${FP}" 0 "fp-f02-prism-js"

FP="${TEST_BASE}/fp-lab-color-$$"
mkdir -p "${FP}"
printf 'Convert to LAB color space\n' > "${FP}/p.txt"
run_gate "${FP}" 0 "fp-f03-lab-color-space"

FP="${TEST_BASE}/fp-lab-domain-$$"
mkdir -p "${FP}"
printf 'contact info@lab.example.org\n' > "${FP}/p.txt"
run_gate "${FP}" 0 "fp-f04-lab-domain-email"

FP="${TEST_BASE}/fp-aura-$$"
mkdir -p "${FP}"
printf 'Built with the Aura component library\n' > "${FP}/p.txt"
run_gate "${FP}" 0 "fp-f05-aura-component"


# ---------------------------------------------------------------------------
# 9. Redaction assertions — verify CI logs never expose raw secrets or
#    denylist terms.
# ---------------------------------------------------------------------------
echo
echo "--- redaction assertions (output must not contain raw secret or denylist term) ---"

check_no_raw_secret() {
    local label="$1"
    local dir="$2"
    local output
    output=$(RELEASE_GATE_DENYLIST_FILE="${EXAMPLE_DENYLIST}" bash "${GATE}" "${dir}" 2>&1 || true)
    # ntn_ tokens are 50+ chars; ntn_ alone in output is a raw leak
    if echo "${output}" | grep -qE 'ntn_[A-Za-z0-9]{10,}'; then
        printf "${RED}FAIL${RESET} gate=%d expected=%d  %s\n" 1 0 "${label} (raw secret in output)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        printf "${GREEN}PASS${RESET} gate=%d expected=%d  %s\n" 0 0 "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

check_no_denylist_term() {
    local label="$1"
    local dir="$2"
    local output
    output=$(RELEASE_GATE_DENYLIST_FILE="${EXAMPLE_DENYLIST}" bash "${GATE}" "${dir}" 2>&1 || true)
    # Check that none of the fake denylist terms appear verbatim in output
    local leaked=0
    while IFS= read -r term; do
        [[ -z "${term}" ]] && continue
        if echo "${output}" | grep -qi "${term}"; then
            leaked=1; break
        fi
    done < "${EXAMPLE_DENYLIST}"
    if [[ "${leaked}" -eq 1 ]]; then
        printf "${RED}FAIL${RESET} gate=%d expected=%d  %s\n" 1 0 "${label} (denylist term leaked to output)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        printf "${GREEN}PASS${RESET} gate=%d expected=%d  %s\n" 0 0 "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

check_no_homepath_username() {
    local label="$1"
    local test_dir="${TEST_BASE}/homepath-redact-$$"
    mkdir -p "${test_dir}"
    printf '/Users/testuser/some/private/path\n' > "${test_dir}/hp.txt"
    local output
    output=$(RELEASE_GATE_DENYLIST_FILE="${EXAMPLE_DENYLIST}" bash "${GATE}" --no-git "${test_dir}" 2>&1 || true)
    if echo "${output}" | grep -qE '/Users/[a-zA-Z0-9_.-]+[^/]'; then
        printf "${RED}FAIL${RESET} gate=%d expected=%d  %s\n" 1 0 "${label} (username in homepath diagnostic)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        printf "${GREEN}PASS${RESET} gate=%d expected=%d  %s\n" 0 0 "${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

# Secret in a UTF-16 file — output must not contain the raw token
check_no_raw_secret "redact-enc-s09-utf16-secret-output" "${ENC_S09}"

# Codename match — output must not print the denylist term
REDACT_MECH="${TEST_BASE}/redact-mech-$$"
mkdir -p "${REDACT_MECH}"
printf 'runs on FAKENODE-ALPHA\n' > "${REDACT_MECH}/p.txt"
check_no_denylist_term "redact-denylist-term-not-in-output" "${REDACT_MECH}"
check_no_homepath_username "redact-homepath-username-not-in-output"

echo
echo "=== results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

[[ "${FAIL_COUNT}" -eq 0 ]]
