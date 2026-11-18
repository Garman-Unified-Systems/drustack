#!/usr/bin/env bash
# release-gate.sh — public-release scanner for DRUstack artifacts.
#
# Six check categories — the gate fails (exit 1) when any find violations:
#   secrets-fs       — gitleaks filesystem scan (working tree) with extended
#                      rules for Notion, OpenAI, Anthropic, HuggingFace, AWS;
#                      archives scanned up to depth 2.
#   secrets-history  — gitleaks git-history scan (--all commits) on patches;
#                      catches secrets that were committed and later deleted.
#   secrets-msgs     — gitleaks FS scan on a dump of all commit messages;
#                      catches secrets that appear only in commit messages
#                      (gitleaks --log-opts scans patches, not messages).
#   secrets-binary   — Python scan of UTF-16/binary files that gitleaks misses;
#                      checks for the same extended secret families.
#   homepaths        — absolute home paths (/Users/<n>, /home/<n>, C:\Users\<n>,
#                      URL-encoded %2FUsers%2F); also scanned in git history.
#   codenames        — names from the private denylist loaded at runtime (see
#                      DENYLIST section below), plus structural patterns
#                      (GOV-NNN governance IDs, CGNAT tailnet addresses); also
#                      scanned in git history (messages + diff patches).
#
# DENYLIST — the private codename list must be provided at runtime:
#   CI:    set the RELEASE_GATE_DENYLIST GitHub Actions secret; the workflow
#          passes it as the RELEASE_GATE_DENYLIST env var (newline or comma-
#          separated list of words to block).
#   Local: create ~/.secrets/release-gate-denylist.txt (one word per line;
#          never committed). Path can be overridden with RELEASE_GATE_DENYLIST_FILE.
#   Test:  RELEASE_GATE_DENYLIST_FILE=scripts/example-denylist.txt uses the
#          public example list of fake names when no real denylist is available.
#   Gate behaviour: if no denylist source is found, the gate FAILS CLOSED.
#
# --no-git mode: pass --no-git to skip all git-history scans. Use when
# scanning an extracted release artifact (a tarball, dist/, etc.) that is not
# a git checkout.
#
# Usage:
#   ./scripts/release-gate.sh [--no-git] [<path>]
#
# Requires: gitleaks >=8.19 (for --max-archive-depth), python3 >=3.8, git.
# Exit codes: 0=clean, 1=violations, 2=required tool missing.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
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

if [[ ! -f "${RULES_FILE}" ]]; then
    printf >&2 "ERROR: Rules file not found: %s\n" "${RULES_FILE}"
    printf >&2 "  Scanning without extended rules reduces coverage — aborting.\n"
    printf >&2 "  In CI: the workflow must fetch scripts/release-gate-rules.toml from main.\n"
    printf >&2 "  Locally: run the script from the repo root or set RULES_FILE=... explicitly.\n"
    exit 1
fi

# Empty ignore-path override: passed to every gitleaks call so a PR-supplied
# .gitleaksignore in the scan root cannot suppress any findings.
GL_EMPTY_IGNORE="$(mktemp)"
trap '/bin/rm -f "${GL_EMPTY_IGNORE}" 2>/dev/null || true' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

pass() { printf "${GREEN}PASS${RESET} %s\n" "$1"; }
fail() { printf "${RED}FAIL${RESET} %s\n" "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }
info() { printf "${YELLOW}INFO${RESET} %s\n" "$1"; }

# ---------------------------------------------------------------------------
# Denylist loading — fail closed when no source is available.
# ---------------------------------------------------------------------------
DENYLIST_WORDS=""

load_denylist() {
    local raw=""
    if [[ -n "${RELEASE_GATE_DENYLIST:-}" ]]; then
        raw="${RELEASE_GATE_DENYLIST}"
    elif [[ -n "${RELEASE_GATE_DENYLIST_FILE:-}" ]] && [[ -f "${RELEASE_GATE_DENYLIST_FILE}" ]]; then
        raw="$(grep -v '^#' "${RELEASE_GATE_DENYLIST_FILE}" | grep -v '^[[:space:]]*$' || true)"
    elif [[ -f "${HOME}/.secrets/release-gate-denylist.txt" ]]; then
        raw="$(grep -v '^#' "${HOME}/.secrets/release-gate-denylist.txt" | grep -v '^[[:space:]]*$' || true)"
    else
        printf >&2 "ERROR: No codename denylist found.\n"
        printf >&2 "  Provide one of:\n"
        printf >&2 "    RELEASE_GATE_DENYLIST=word1,word2,...  (env var)\n"
        printf >&2 "    RELEASE_GATE_DENYLIST_FILE=/path/to/list (env var pointing to file)\n"
        printf >&2 "    %s/.secrets/release-gate-denylist.txt (local file)\n" "${HOME}"
        printf >&2 "  For local testing use the public example list:\n"
        printf >&2 "    RELEASE_GATE_DENYLIST_FILE=%s/example-denylist.txt\n" "${SCRIPT_DIR}"
        exit 1
    fi
    DENYLIST_WORDS="$(printf '%s' "${raw}" | tr ',\n' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort -u)"
}

# ---------------------------------------------------------------------------
# Exact exclusion paths for the Python scanner.
# These match the gitleaks [allowlist] paths in release-gate-rules.toml.
# EXCLUDED_DIR_PREFIX: relpath directory (without trailing slash); a file
#   must start with this prefix + '/' OR equal it exactly.
# EXCLUDED_EXACT_FILES: exact relpaths that are excluded entirely.
# ---------------------------------------------------------------------------
EXCLUDED_DIR_PREFIX="tests/fixtures/should-fail"
EXCLUDED_EXACT_FILES=(
    "scripts/release-gate.sh"
    "scripts/release-gate-rules.toml"
)

# ---------------------------------------------------------------------------
# Python scanner — filesystem walker + text pattern checker.
#
# IMPORTANT: the heredoc below uses <<'PYEOF' (single-quoted) so bash does
# NOT process backslashes or variables inside it.  All inputs are passed
# via sys.argv and env vars, never embedded in the heredoc.
#
# Modes (sys.argv[1]):
#   homepath-wt      scan working-tree directory for home paths
#   codename-wt      scan working-tree directory for codenames (uses DENYLIST)
#   secrets-wt       scan working-tree directory for secrets in binary/UTF-16
#   secrets-text     scan working-tree directory for secrets in text files (gitleaks-bypass backstop)
#   homepath-file    scan a pre-generated text file for home paths
#   codename-file    scan a pre-generated text file for codenames
#
# sys.argv[2]  : scan target (directory or file path)
# sys.argv[3]  : excluded directory prefix (relpath, no trailing slash)
# sys.argv[4:] : excluded exact file relpaths
#
# Env vars:
#   RELEASE_GATE_DENYLIST_WORDS : newline-separated denylist words
# ---------------------------------------------------------------------------
run_python_scanner() {
    local mode="$1"
    local target="$2"
    export RELEASE_GATE_DENYLIST_WORDS="${DENYLIST_WORDS}"

    python3 - "${mode}" "${target}" \
        "${EXCLUDED_DIR_PREFIX}" \
        "${EXCLUDED_EXACT_FILES[@]}" \
        <<'PYEOF'
import sys, re, os

mode       = sys.argv[1]
target     = sys.argv[2]
excl_dir   = sys.argv[3]
excl_files = sys.argv[4:]

# ---------------------------------------------------------------------------
# Home-path patterns
# ---------------------------------------------------------------------------
HOMEPATH_RE = re.compile(
    r'/Users/[^/\s"\'>{}\|\\]+'
    r'|/home/[^/\s"\'>{}\|\\]+'
    r'|[A-Za-z]:\\Users\\[^\\\s]+'
    r'|%2F[Uu]sers%2F[^/\s"\'&?#]+'
    , re.IGNORECASE
)

# ---------------------------------------------------------------------------
# Extended secret patterns (for binary/UTF-16 files gitleaks may miss)
# ---------------------------------------------------------------------------
SECRETS_RE = re.compile(
    r'ntn_[0-9A-Za-z]{40,}'
    r'|sk-(?:proj-)?[0-9A-Za-z\-_]{40,}'
    r'|sk-ant-[0-9A-Za-z\-_]{80,}'
    r'|hf_[a-zA-Z0-9]{30,}'
    r'|AKIA[0-9A-Z]{16}'
    r'|ghp_[A-Za-z0-9]{36}'
    r'|ghs_[A-Za-z0-9]{36}'
    , re.IGNORECASE
)

# ---------------------------------------------------------------------------
# False-positive suppression patterns (suppress denylist match on this line)
# ---------------------------------------------------------------------------
FALSE_POSITIVE_RES = [
    re.compile(r'\bLAB\s+(?:color|colour|space|mode)\b',    re.IGNORECASE),
    re.compile(r'(?:color|colour)(?:\s+space)?\s+LAB\b',    re.IGNORECASE),
    re.compile(r'\bCIE\s+LAB\b',                            re.IGNORECASE),
    re.compile(r'\bPrism\.js\b',                            re.IGNORECASE),
    re.compile(r'\bPrism\s+\.js\b',                         re.IGNORECASE),
    re.compile(r'\bAura\s+component\b',                     re.IGNORECASE),
    re.compile(r'\bAura\s+framework\b',                     re.IGNORECASE),
    re.compile(r'\w+@lab\.[a-z]',                           re.IGNORECASE),
]

def is_false_positive(line):
    return any(fp.search(line) for fp in FALSE_POSITIVE_RES)

# ---------------------------------------------------------------------------
# Structural patterns (always applied; no denylist needed)
# ---------------------------------------------------------------------------
STRUCTURAL_RE = re.compile(
    r'\bGOV[-_ ]?\d{2,}\b'
    r'|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}'
    , re.IGNORECASE
)

# ---------------------------------------------------------------------------
# Denylist pattern builder
# Short words (<=5 alpha chars): match with optional separators between
# letters to catch G.U.S / G-U-S / G_U-S style abbreviations.
# Multi-word entries (containing space): also allow [-_] as separator.
# All matches are case-insensitive.
# ---------------------------------------------------------------------------
def build_denylist_re(words):
    if not words:
        return None
    parts = []
    for w in words:
        w = w.strip()
        if not w:
            continue
        sep = r'[.\-_ ]?'
        if len(w) <= 5 and re.match(r'^[A-Za-z]+$', w):
            # Punctuation-tolerant abbreviation matching
            escaped = sep.join(re.escape(c) for c in w)
            parts.append(r'(?<![A-Za-z0-9])' + escaped + r'(?![A-Za-z0-9])')
        else:
            parts.append(r'\b' + re.escape(w) + r'\b')
    if not parts:
        return None
    return re.compile('|'.join(parts), re.IGNORECASE)

raw_denylist  = os.environ.get('RELEASE_GATE_DENYLIST_WORDS', '')
denylist_words = [w.strip() for w in raw_denylist.splitlines() if w.strip()]
DENYLIST_RE    = build_denylist_re(denylist_words)
scan_errors = []

# ---------------------------------------------------------------------------
# File reading with UTF-16 BOM detection and latin-1 fallback for binary
# ---------------------------------------------------------------------------
def read_lines(fpath):
    try:
        with open(fpath, 'rb') as fh:
            data = fh.read()
        if data[:2] in (b'\xff\xfe', b'\xfe\xff'):
            try:
                return data.decode('utf-16', errors='replace').splitlines()
            except Exception:
                pass
        return data.decode('latin-1', errors='replace').splitlines()
    except (OSError, PermissionError):
        scan_errors.append('[scan-error]: unreadable file (path redacted)')
        return []

# ---------------------------------------------------------------------------
# Exclusion check — exact directory prefix or exact file match
# ---------------------------------------------------------------------------
def is_excluded(relpath):
    norm = relpath.replace(os.sep, '/')
    prefix = excl_dir.rstrip('/')
    if norm.startswith(prefix + '/') or norm == prefix:
        return True
    return norm in excl_files

# ---------------------------------------------------------------------------
# Hit formatter — redacts sensitive content from scan output so CI logs
# never expose secrets or private denylist terms.
# ---------------------------------------------------------------------------
def format_hit(label_prefix, lineno, line):
    if mode.startswith('secrets'):
        m = SECRETS_RE.search(line)
        if m:
            matched = m.group(0)
            family = matched[:4] if len(matched) >= 4 else matched
            return '{:s}:{:d}:[secret detected: {:s}***]'.format(
                label_prefix, lineno, family)
        return '{:s}:{:d}:[secret detected]'.format(label_prefix, lineno)
    elif mode.startswith('codename'):
        # Never print the matched codename — it comes from the private
        # denylist and must not appear in CI logs.
        if STRUCTURAL_RE.search(line) and not is_false_positive(line):
            family = 'structural-pattern'
        else:
            family = 'codename-match'
        return '{:s}:{:d}:[{:s}]'.format(label_prefix, lineno, family)
    else:  # homepath
        m = HOMEPATH_RE.search(line)
        if m:
            matched = m.group(0)
            # Redact username: never emit the actual username in diagnostics.
            norm = matched.replace('\\', '/')
            if re.match(r'^/[Uu]sers/', norm):
                prefix = '/Users'
            elif re.match(r'^/[Hh]ome/', norm):
                prefix = '/home'
            elif re.match(r'^%2F[Uu]sers%2F', norm, re.IGNORECASE):
                prefix = '%2FUsers%2F'
            else:
                prefix = '[path]'
            return '{:s}:{:d}:{:s}/[redacted]/[...]'.format(label_prefix, lineno, prefix)
        return '{:s}:{:d}:[homepath detected]'.format(label_prefix, lineno)

# ---------------------------------------------------------------------------
# Line scanner
# ---------------------------------------------------------------------------
def scan_lines(lines, label_prefix):
    hits = []
    for lineno, line in enumerate(lines, 1):
        matched = False
        if mode.startswith('homepath'):
            matched = bool(HOMEPATH_RE.search(line))
        elif mode.startswith('secrets'):
            matched = bool(SECRETS_RE.search(line))
        else:  # codename
            if STRUCTURAL_RE.search(line) and not is_false_positive(line):
                matched = True
            elif DENYLIST_RE and DENYLIST_RE.search(line) and not is_false_positive(line):
                matched = True
        if matched:
            hits.append(format_hit(label_prefix, lineno, line))
        if len(hits) >= 30:
            break
    return hits

hits = []

if mode.endswith('-wt') or mode == 'secrets-text':
    for dirpath, dirnames, filenames in os.walk(target):
        dirnames[:] = [d for d in dirnames if d != '.git']
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            rel   = os.path.relpath(fpath, target)
            if is_excluded(rel):
                continue
            # secrets-wt: only binary/UTF-16; secrets-text: only plain text
            if mode in ('secrets-wt', 'secrets-text'):
                try:
                    with open(fpath, 'rb') as fh:
                        raw = fh.read(512)
                    is_utf16 = raw[:2] in (b'\xff\xfe', b'\xfe\xff')
                    has_nul  = b'\x00' in raw
                    is_binary = is_utf16 or has_nul
                    if mode == 'secrets-wt' and not is_binary:
                        continue
                    if mode == 'secrets-text' and is_binary:
                        continue
                except (OSError, PermissionError):
                    continue
            lines = read_lines(fpath)
            hits.extend(scan_lines(lines, rel))
            if len(hits) >= 30:
                break
        if len(hits) >= 30:
            break
elif mode.endswith('-file'):
    with open(target, encoding='latin-1', errors='replace') as fh:
        lines = fh.read().splitlines()
    hits.extend(scan_lines(lines, target))

for hit in hits[:30]:
    print(hit)

for err in scan_errors[:5]:
    print(err)
sys.exit(1 if hits or scan_errors else 0)
PYEOF
}

# ---------------------------------------------------------------------------
# Check 1: secrets — filesystem scan (working tree)
# ---------------------------------------------------------------------------
check_secrets_fs() {
    local extra_args=()
    [[ -f "${RULES_FILE}" ]] && extra_args+=(--config "${RULES_FILE}") \
        || info "Extended rules file not found; using gitleaks defaults (misses some families)."
    extra_args+=(--ignore-gitleaks-allow --gitleaks-ignore-path "${GL_EMPTY_IGNORE}")

    info "Scanning filesystem for secrets (archives up to depth 2) ..."
    local tmp_report; tmp_report="$(mktemp)"

    local gl_exit=0
    gitleaks detect \
        --source "${SCAN_ROOT}" \
        --report-path "${tmp_report}" \
        --report-format json \
        --no-git \
        --max-archive-depth 2 \
        --redact \
        "${extra_args[@]}" 2>/dev/null || gl_exit=$?

    _handle_gitleaks_exit "${gl_exit}" "${tmp_report}" "secrets-fs"
    /bin/rm -f "${tmp_report}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Check 2: secrets — git history scan (patches/blobs)
# ---------------------------------------------------------------------------
check_secrets_history() {
    if [[ "${SKIP_GIT_HISTORY}" -eq 1 ]]; then
        info "Skipping history patch scan (--no-git)."; return
    fi
    if ! git -C "${SCAN_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        info "Skipping history patch scan (not a git repo)."; return
    fi

    local extra_args=()
    [[ -f "${RULES_FILE}" ]] && extra_args+=(--config "${RULES_FILE}")
    extra_args+=(--ignore-gitleaks-allow --gitleaks-ignore-path "${GL_EMPTY_IGNORE}")

    info "Scanning git history patches for secrets ..."
    local tmp_report; tmp_report="$(mktemp)"

    local gl_exit=0
    gitleaks detect \
        --source "${SCAN_ROOT}" \
        --report-path "${tmp_report}" \
        --report-format json \
        --log-opts="--all" \
        --max-archive-depth 2 \
        --redact \
        "${extra_args[@]}" 2>/dev/null || gl_exit=$?

    _handle_gitleaks_exit "${gl_exit}" "${tmp_report}" "secrets-history"
    /bin/rm -f "${tmp_report}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Check 3: secrets — commit messages (gitleaks scans patches, not messages)
# ---------------------------------------------------------------------------
check_secrets_commit_msgs() {
    if [[ "${SKIP_GIT_HISTORY}" -eq 1 ]]; then
        info "Skipping commit-message secret scan (--no-git)."; return
    fi
    if ! git -C "${SCAN_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        info "Skipping commit-message secret scan (not a git repo)."; return
    fi

    local extra_args=()
    [[ -f "${RULES_FILE}" ]] && extra_args+=(--config "${RULES_FILE}")
    extra_args+=(--ignore-gitleaks-allow --gitleaks-ignore-path "${GL_EMPTY_IGNORE}")

    info "Scanning commit messages for secrets ..."

    local tmp_msgs; tmp_msgs="$(mktemp)"
    git -C "${SCAN_ROOT}" log --all --format="%B" > "${tmp_msgs}" 2>/dev/null || true

    local tmp_report; tmp_report="$(mktemp)"
    local gl_exit=0
    gitleaks detect \
        --source "${tmp_msgs}" \
        --report-path "${tmp_report}" \
        --report-format json \
        --no-git \
        --redact \
        "${extra_args[@]}" 2>/dev/null || gl_exit=$?

    _handle_gitleaks_exit "${gl_exit}" "${tmp_report}" "secrets-commit-msgs"
    /bin/rm -f "${tmp_msgs}" "${tmp_report}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Check 4a: gitleaksignore gate — a PR-supplied ignore file is a bypass attempt
# ---------------------------------------------------------------------------
check_no_gitleaksignore() {
    if [[ -f "${SCAN_ROOT}/.gitleaksignore" ]]; then
        fail "secrets-bypass: .gitleaksignore found in scan root — remove it before release"
        printf "  File: %s/.gitleaksignore\n" "${SCAN_ROOT}"
        printf "  A .gitleaksignore suppresses gitleaks findings. It must not be committed.\n"
    else
        pass "secrets-bypass: no .gitleaksignore in scan root"
    fi
}

# ---------------------------------------------------------------------------
# Check 4b: secrets — text files (Python SECRETS_RE backstop)
#
# Independent of gitleaks. Cannot be suppressed by .gitleaksignore or
# gitleaks:allow comments. Catches the same secret families the gitleaks
# extended rules cover but via direct regex over every UTF-8 text file.
# ---------------------------------------------------------------------------
check_secrets_text() {
    info "Scanning text files for secrets (Python SECRETS_RE backstop) ..."

    local scan_exit=0
    local hits
    hits=$(run_python_scanner "secrets-text" "${SCAN_ROOT}" 2>/dev/null) || scan_exit=$?

    if [[ "${scan_exit}" -ne 0 ]] || [[ -n "${hits}" ]]; then
        fail "secrets-text: SECRETS_RE backstop found matches in text files"
        while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${hits}"
    else
        pass "secrets-text: no SECRETS_RE matches in text files"
    fi
}

# ---------------------------------------------------------------------------
# Check 4c: secrets — binary and UTF-16 files (Python scanner)
# ---------------------------------------------------------------------------
check_secrets_binary() {
    info "Scanning binary/UTF-16 files for secrets ..."

    local scan_exit=0
    local hits
    hits=$(run_python_scanner "secrets-wt" "${SCAN_ROOT}" 2>/dev/null) || scan_exit=$?

    if [[ "${scan_exit}" -ne 0 ]] || [[ -n "${hits}" ]]; then
        fail "secrets-binary: secrets found in binary/UTF-16 files"
        while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${hits}"
    else
        pass "secrets-binary: no secrets in binary/UTF-16 files"
    fi
}

_handle_gitleaks_exit() {
    local gl_exit="$1"
    local tmp_report="$2"
    local label="$3"

    if [[ "${gl_exit}" -eq 1 ]]; then
        fail "${label}: gitleaks found secrets"
        python3 - "${tmp_report}" <<'JEOF' 2>/dev/null || true
import json, re, sys
try:
    data = json.load(open(sys.argv[1]))
    if isinstance(data, list):
        for hit in data[:10]:
            commit = hit.get("Commit", "")
            commit_disp = " commit={}".format(commit[:8]) if commit else ""
            raw_file = hit.get('File', '?')
            safe_file = re.sub(r'(/Users/|/home/)[^/\s]+', r'\1[redacted]', raw_file, flags=re.IGNORECASE)
            print("  {}  {}:{}{}".format(
                hit.get('RuleID','?'), safe_file,
                hit.get('StartLine','?'), commit_disp))
        if len(data) > 10:
            print("  ... and {} more".format(len(data) - 10))
except Exception:
    pass
JEOF
    elif [[ "${gl_exit}" -ne 0 ]]; then
        fail "${label}: gitleaks exited with unexpected code ${gl_exit}"
    else
        pass "${label}: gitleaks clean"
    fi
}

# ---------------------------------------------------------------------------
# Check 5: home paths — working tree
# ---------------------------------------------------------------------------
check_homepaths() {
    info "Scanning working tree for absolute home paths ..."

    local scan_exit=0
    local hits
    hits=$(run_python_scanner "homepath-wt" "${SCAN_ROOT}" 2>/dev/null) || scan_exit=$?

    if [[ "${scan_exit}" -ne 0 ]] || [[ -n "${hits}" ]]; then
        fail "homepaths: absolute home paths found"
        while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${hits}"
    else
        pass "homepaths: no absolute home paths"
    fi
}

# ---------------------------------------------------------------------------
# Check 6: codenames — working tree
# ---------------------------------------------------------------------------
check_codenames() {
    info "Scanning working tree for codenames ..."

    local scan_exit=0
    local hits
    hits=$(run_python_scanner "codename-wt" "${SCAN_ROOT}" 2>/dev/null) || scan_exit=$?

    if [[ "${scan_exit}" -ne 0 ]] || [[ -n "${hits}" ]]; then
        fail "codenames: internal names found"
        while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${hits}"
    else
        pass "codenames: clean"
    fi
}

# ---------------------------------------------------------------------------
# Check 7: git history text — commit messages + diff patches for home paths
#          and codenames; catches content committed then deleted.
# ---------------------------------------------------------------------------
check_history_text() {
    if [[ "${SKIP_GIT_HISTORY}" -eq 1 ]]; then
        info "Skipping history text scan (--no-git)."; return
    fi
    if ! git -C "${SCAN_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        info "Skipping history text scan (not a git repo)."; return
    fi

    info "Scanning git history text (messages + diff patches) ..."

    local tmp_history; tmp_history="$(mktemp)"

    # All commit messages (all branches, full body)
    git -C "${SCAN_ROOT}" log --all --format="%B" >> "${tmp_history}" 2>/dev/null || true

    # Content that was ever added in any commit (strips diff + header lines)
    git -C "${SCAN_ROOT}" log --all -p --format="" 2>/dev/null \
        | python3 -c '
import sys
for line in sys.stdin:
    if line.startswith("+") and not line.startswith("+++"):
        sys.stdout.write(line[1:])
' >> "${tmp_history}" 2>/dev/null || true

    local hp_exit=0
    local hp_hits
    hp_hits=$(run_python_scanner "homepath-file" "${tmp_history}" 2>/dev/null) || hp_exit=$?

    if [[ "${hp_exit}" -ne 0 ]] || [[ -n "${hp_hits}" ]]; then
        fail "history-homepaths: home paths in git history"
        while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${hp_hits}"
    else
        pass "history-homepaths: clean"
    fi

    local cn_exit=0
    local cn_hits
    cn_hits=$(run_python_scanner "codename-file" "${tmp_history}" 2>/dev/null) || cn_exit=$?

    if [[ "${cn_exit}" -ne 0 ]] || [[ -n "${cn_hits}" ]]; then
        fail "history-codenames: codenames in git history"
        while IFS= read -r line; do printf "  %s\n" "${line}"; done <<< "${cn_hits}"
    else
        pass "history-codenames: clean"
    fi

    /bin/rm -f "${tmp_history}" 2>/dev/null || true
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

    load_denylist

    printf "=== release-gate scan: %s ===\n" "$(realpath "${SCAN_ROOT}")"
    printf "timestamp: %s\n\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    check_no_gitleaksignore
    echo
    check_secrets_fs
    echo
    check_secrets_history
    echo
    check_secrets_commit_msgs
    echo
    check_secrets_text
    echo
    check_secrets_binary
    echo
    check_homepaths
    echo
    check_codenames
    echo
    check_history_text
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
