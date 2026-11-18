#!/usr/bin/env bash
# release-gate.sh — public-release scanner for DRUstack artifacts.
#
# Fails (exit 1) when any of four checks find violations:
#   secrets-fs       — gitleaks filesystem scan (working tree) with extended
#                      rules for Notion, OpenAI, Anthropic, HuggingFace, AWS.
#   secrets-history  — gitleaks git-history scan (--all commits) with the
#                      same extended rules; catches secrets that were committed
#                      and later deleted. Runs only when inside a git repo.
#   homepaths        — absolute paths embedding a username (/Users/<n>, /home/<n>).
#   codenames        — internal fleet names, bead IDs, GOV-### rule IDs, and
#                      tool names that must not appear in public artifacts.
#
# --no-git mode: pass --no-git to skip the history scan. Use this when
# scanning an extracted release artifact (a tarball, dist/ folder, or any
# path that is not a git checkout). The filesystem scan still runs.
#
# Usage:
#   ./scripts/release-gate.sh [--no-git] [<path>]
#
# Requires:
#   - gitleaks >=8.0 on PATH (https://github.com/gitleaks/gitleaks)
#   - python3 >=3.8 on PATH
#   - git (for history scan; skipped with --no-git)
#
# Exit codes:
#   0  all checks passed
#   1  one or more violations found (details printed to stdout)
#   2  required tool not found on PATH

set -euo pipefail

SKIP_GIT_HISTORY=0
SCAN_ROOT=""

for arg in "$@"; do
    case "${arg}" in
        --no-git) SKIP_GIT_HISTORY=1 ;;
        *)        SCAN_ROOT="${arg}" ;;
    esac
done
SCAN_ROOT="${SCAN_ROOT:-.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="${SCRIPT_DIR}/release-gate-rules.toml"
VIOLATIONS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

pass() { printf "${GREEN}PASS${RESET} %s\n" "$1"; }
fail() { printf "${RED}FAIL${RESET} %s\n" "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }
info() { printf "${YELLOW}INFO${RESET} %s\n" "$1"; }

# ---------------------------------------------------------------------------
# Shared Python scanner
# Uses python3 re for home-path and codename matching. This avoids
# relying on grep -P, which macOS BSD grep does not support.
#
# Paths in EXCLUDED_SCAN_PATHS are always skipped by the Python scanner.
# They match paths in the allowlist section of release-gate-rules.toml so
# the scanner's own test fixtures and pattern source are excluded from
# every check while every other path in the repo stays covered.
# ---------------------------------------------------------------------------
EXCLUDED_SCAN_PATHS=(
    "tests/fixtures/should-fail"
    "scripts/release-gate.sh"
    "scripts/release-gate-rules.toml"
)

python_scan() {
    local pattern_type="$1"
    local scan_root="$2"
    shift 2
    local excluded=("$@")

    python3 - "${pattern_type}" "${scan_root}" "${excluded[@]}" <<'PYEOF'
import sys
import re
import os

pattern_type = sys.argv[1]
scan_root = sys.argv[2]
excluded_paths = sys.argv[3:]

HOMEPATH_PATTERN = re.compile(
    r'/Users/[^/\s"\'>{}\|\\]+'
    r'|/home/[^/\s"\'>{}\|\\]+'
)

# Allowlist: GUSystems (contains GUS), DRUstack (contains DRU),
#            dbnt, ABCDxDBNTxKISS — approved public brand names.
CODENAME_PATTERN = re.compile(
    r'(?<![A-Za-z])GUS(?!ystems|[A-Za-z])'
    r'|(?<![A-Za-z])DRU(?!stack|[A-Za-z])'
    r'|\bPAM\b'
    r'|\bORB\b'
    r'|\bGRU\b'
    r'|\bLAB\b'
    r'|\bMama\b'
    r'|\bREX\b'
    r'|\bGMA\b'
    r'|\bMelvil\b'
    r'|\bCassi\b'
    r'|\bAeon\b'
    r'|\bMcAvoy\b'
    r'|\bAura\b'
    r'|\bPrism\b'
    r'|\bChorus\b'
    r'|\b(?:bosun|foreman|warden|curator|scout)@\w+'
    r'|\b\w+@(?:dru|gus|mama|lab|rex|gma)\b'
    r'|\bdru-[a-z0-9]{4,8}\b'
    r'|\bGOV-\d{3,}\b'
    r'|\bmesh-bus\b'
    r'|\bmemo-bus\b'
    r'|\bcc-bus\b'
    r'|\bVAUL4\b'
    r'|\bDD4\b'
    r'|Grind\s+Time'
    r'|Dizzy\s+Decimal'
    r'|minis-mac-mini'
)

pattern = HOMEPATH_PATTERN if pattern_type == "homepath" else CODENAME_PATTERN

def is_excluded(fpath):
    rel = os.path.relpath(fpath, scan_root)
    for exc in excluded_paths:
        if rel.startswith(exc) or exc in rel:
            return True
    return False

hits = []
for dirpath, dirnames, filenames in os.walk(scan_root):
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for fname in filenames:
        fpath = os.path.join(dirpath, fname)
        if is_excluded(fpath):
            continue
        try:
            with open(fpath, encoding="utf-8", errors="replace") as f:
                for lineno, line in enumerate(f, 1):
                    if pattern.search(line):
                        hits.append(f"{fpath}:{lineno}:{line.rstrip()}")
                        if len(hits) >= 30:
                            break
        except (OSError, PermissionError):
            pass
    if len(hits) >= 30:
        break

for hit in hits:
    print(hit)

sys.exit(1 if hits else 0)
PYEOF
}

# ---------------------------------------------------------------------------
# Check 1: secrets — filesystem scan (working tree)
# ---------------------------------------------------------------------------
check_secrets_fs() {
    local extra_args=()
    if [[ -f "${RULES_FILE}" ]]; then
        extra_args+=(--config "${RULES_FILE}")
    else
        info "Extended rules file not found at ${RULES_FILE}; using gitleaks defaults only."
        info "WARNING: gitleaks defaults miss Notion, OpenAI, Anthropic, HuggingFace, AWS families."
    fi

    info "Scanning filesystem (working tree) for secrets ..."

    local tmp_report
    tmp_report="$(mktemp)"

    local gl_exit=0
    gitleaks detect \
        --source "${SCAN_ROOT}" \
        --report-path "${tmp_report}" \
        --report-format json \
        --no-git \
        --redact \
        "${extra_args[@]}" 2>/dev/null || gl_exit=$?

    _handle_gitleaks_exit "${gl_exit}" "${tmp_report}" "secrets-fs"
    /bin/rm -f "${tmp_report}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Check 2: secrets — git history scan (all commits)
# Catches secrets that were committed then deleted.
# Skipped with --no-git or when SCAN_ROOT is not a git repository.
# ---------------------------------------------------------------------------
check_secrets_history() {
    if [[ "${SKIP_GIT_HISTORY}" -eq 1 ]]; then
        info "Skipping history scan (--no-git)."
        return
    fi

    if ! git -C "${SCAN_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        info "Skipping history scan (${SCAN_ROOT} is not a git repository)."
        return
    fi

    local extra_args=()
    if [[ -f "${RULES_FILE}" ]]; then
        extra_args+=(--config "${RULES_FILE}")
    fi

    info "Scanning git history (all commits) for secrets ..."

    local tmp_report
    tmp_report="$(mktemp)"

    local gl_exit=0
    gitleaks detect \
        --source "${SCAN_ROOT}" \
        --report-path "${tmp_report}" \
        --report-format json \
        --log-opts="--all" \
        --redact \
        "${extra_args[@]}" 2>/dev/null || gl_exit=$?

    _handle_gitleaks_exit "${gl_exit}" "${tmp_report}" "secrets-history"
    /bin/rm -f "${tmp_report}" 2>/dev/null || true
}

_handle_gitleaks_exit() {
    local gl_exit="$1"
    local tmp_report="$2"
    local label="$3"

    if [[ "${gl_exit}" -eq 1 ]]; then
        fail "${label}: gitleaks found secrets"
        python3 - "${tmp_report}" <<'EOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    if isinstance(data, list):
        for hit in data[:10]:
            commit = hit.get("Commit", "")
            commit_disp = f" commit={commit[:8]}" if commit else ""
            print(f"  {hit.get('RuleID','?')}  {hit.get('File','?')}:{hit.get('StartLine','?')}{commit_disp}")
        if len(data) > 10:
            print(f"  ... and {len(data)-10} more")
except Exception:
    pass
EOF
    elif [[ "${gl_exit}" -ne 0 ]]; then
        fail "${label}: gitleaks exited with unexpected code ${gl_exit}"
    else
        pass "${label}: gitleaks clean"
    fi
}

# ---------------------------------------------------------------------------
# Check 3: absolute home paths
# ---------------------------------------------------------------------------
check_homepaths() {
    info "Scanning for absolute home paths ..."

    local scan_exit=0
    local hits
    hits=$(python_scan "homepath" "${SCAN_ROOT}" "${EXCLUDED_SCAN_PATHS[@]}" 2>/dev/null) || scan_exit=$?

    if [[ "${scan_exit}" -ne 0 ]] || [[ -n "${hits}" ]]; then
        fail "homepaths: absolute home paths found"
        while IFS= read -r line; do
            printf "  %s\n" "${line}"
        done <<< "${hits}"
    else
        pass "homepaths: no absolute home paths found"
    fi
}

# ---------------------------------------------------------------------------
# Check 4: codenames
# ---------------------------------------------------------------------------
check_codenames() {
    info "Scanning for internal codenames ..."

    local scan_exit=0
    local hits
    hits=$(python_scan "codename" "${SCAN_ROOT}" "${EXCLUDED_SCAN_PATHS[@]}" 2>/dev/null) || scan_exit=$?

    if [[ "${scan_exit}" -ne 0 ]] || [[ -n "${hits}" ]]; then
        fail "codenames: internal names found"
        while IFS= read -r line; do
            printf "  %s\n" "${line}"
        done <<< "${hits}"
    else
        pass "codenames: no internal codenames found"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if ! command -v gitleaks >/dev/null 2>&1; then
        printf >&2 "ERROR: gitleaks not found on PATH.\n"
        printf >&2 "Install: https://github.com/gitleaks/gitleaks/releases\n"
        exit 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf >&2 "ERROR: python3 not found on PATH.\n"
        exit 2
    fi

    printf "=== release-gate scan: %s ===\n" "$(realpath "${SCAN_ROOT}")"
    printf "timestamp: %s\n\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    check_secrets_fs
    echo
    check_secrets_history
    echo
    check_homepaths
    echo
    check_codenames
    echo

    if [[ "${VIOLATIONS}" -gt 0 ]]; then
        printf "${RED}GATE FAILED${RESET}: %d violation class(es). Fix before publishing.\n" "${VIOLATIONS}"
        exit 1
    else
        printf "${GREEN}GATE PASSED${RESET}: all checks clean.\n"
        exit 0
    fi
}

main
