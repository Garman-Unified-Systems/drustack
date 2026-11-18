#!/usr/bin/env bash
# release-gate.sh — public-release scanner for DRUstack artifacts.
#
# Fails (exit 1) when any of three classes of violations are found:
#   secrets   — gitleaks with extended rules covering Notion, OpenAI, Anthropic,
#               HuggingFace, and AWS (gitleaks default rules miss these families).
#   homepaths — absolute paths that embed a username (/Users/<name>, /home/<name>).
#   codenames — internal fleet names, bead IDs, GOV-### rule IDs, and tool names
#               that must not appear in public artifacts.
#
# Usage:
#   ./scripts/release-gate.sh [<path>]
#
#   <path>  directory to scan (default: current directory).
#
# Requires:
#   - gitleaks >=8.0 on PATH (https://github.com/gitleaks/gitleaks)
#   - python3 >=3.8 on PATH (for home-path and codename scans)
#
# Exit codes:
#   0  all checks passed
#   1  one or more violations found (details printed to stdout)
#   2  required tool not found on PATH

set -euo pipefail

SCAN_ROOT="${1:-.}"
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
# Wraps file-walking + regex matching so we don't depend on grep -P,
# which macOS BSD grep does not support.
# ---------------------------------------------------------------------------
python_scan() {
    # Args: pattern_type ("homepath"|"codename") scan_root
    local pattern_type="$1"
    local scan_root="$2"

    python3 - "${pattern_type}" "${scan_root}" <<'PYEOF'
import sys
import re
import os

pattern_type = sys.argv[1]
scan_root = sys.argv[2]

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

hits = []
for dirpath, dirnames, filenames in os.walk(scan_root):
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for fname in filenames:
        fpath = os.path.join(dirpath, fname)
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
# Check 1: secrets (gitleaks + extended rules)
# ---------------------------------------------------------------------------
check_secrets() {
    if ! command -v gitleaks >/dev/null 2>&1; then
        printf >&2 "ERROR: gitleaks not found on PATH.\n"
        printf >&2 "Install: https://github.com/gitleaks/gitleaks/releases\n"
        exit 2
    fi

    local extra_args=()
    if [[ -f "${RULES_FILE}" ]]; then
        extra_args+=(--config "${RULES_FILE}")
    else
        info "Extended rules file not found at ${RULES_FILE}; using gitleaks defaults only."
        info "WARNING: gitleaks defaults miss Notion, OpenAI, Anthropic, HuggingFace, AWS families."
    fi

    info "Running gitleaks on ${SCAN_ROOT} ..."

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

    if [[ "${gl_exit}" -eq 1 ]]; then
        fail "secrets: gitleaks found secrets (exit ${gl_exit})"
        python3 - "${tmp_report}" <<'EOF' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    if isinstance(data, list):
        for hit in data[:10]:
            print(f"  {hit.get('RuleID','?')}  {hit.get('File','?')}:{hit.get('StartLine','?')}")
        if len(data) > 10:
            print(f"  ... and {len(data)-10} more")
except Exception:
    pass
EOF
    elif [[ "${gl_exit}" -ne 0 ]]; then
        fail "secrets: gitleaks exited with unexpected code ${gl_exit}"
    else
        pass "secrets: gitleaks clean"
    fi

    /bin/rm -f "${tmp_report}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Check 2: absolute home paths
# ---------------------------------------------------------------------------
check_homepaths() {
    if ! command -v python3 >/dev/null 2>&1; then
        printf >&2 "ERROR: python3 not found on PATH.\n"
        exit 2
    fi

    info "Scanning for absolute home paths in ${SCAN_ROOT} ..."

    local scan_exit=0
    local hits
    hits=$(python_scan "homepath" "${SCAN_ROOT}" 2>/dev/null) || scan_exit=$?

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
# Check 3: codenames
# ---------------------------------------------------------------------------
# Allowlist: GUSystems (contains GUS), DRUstack (contains DRU),
#            dbnt, ABCDxDBNTxKISS — approved public brand names.
check_codenames() {
    if ! command -v python3 >/dev/null 2>&1; then
        printf >&2 "ERROR: python3 not found on PATH.\n"
        exit 2
    fi

    info "Scanning for internal codenames in ${SCAN_ROOT} ..."

    local scan_exit=0
    local hits
    hits=$(python_scan "codename" "${SCAN_ROOT}" 2>/dev/null) || scan_exit=$?

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
    printf "=== release-gate scan: %s ===\n" "$(realpath "${SCAN_ROOT}")"
    printf "timestamp: %s\n\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    check_secrets
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
