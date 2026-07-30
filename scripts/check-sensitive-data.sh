#!/usr/bin/env bash
# Copyright 2026 Alibaba Cloud
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Sensitive-data gate: refuses commits/PRs that introduce IP addresses,
# passwords, API keys, tokens or private keys.
#
# Modes:
#   --staged            scan lines ADDED in the staged diff (pre-commit; default)
#   --diff <range>      scan lines ADDED in a diff range (CI: base...head)
#   --all               scan every tracked text file (audit mode)
#   --install-hook      install a .git/hooks/pre-commit that runs --staged
#
# Only ADDED lines are scanned in --staged/--diff so pre-existing history
# never blocks unrelated work; full-tree audits use --all.
#
# False positives: add a line-matching ERE to .github/sensitive-scan-allowlist.txt
# (one per line, '#' comments allowed) with a justification comment above it.
#
# Exit codes: 0 = clean, 1 = findings (commit/PR must be rejected), 2 = usage.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ALLOWLIST="$REPO_ROOT/.github/sensitive-scan-allowlist.txt"

# --- detection patterns (ERE) -----------------------------------------------
# Each entry: "<label>\t<pattern>". Patterns aim for high signal; the
# allowlist absorbs the rare legitimate hit rather than loosening these.
PATTERNS=(
    $'private-key\t-----BEGIN [A-Z ]*PRIVATE KEY-----'
    $'openai-style-key\t\\bsk-[A-Za-z0-9_-]{16,}\\b'
    $'aws-access-key\t\\bAKIA[0-9A-Z]{16}\\b'
    $'github-token\t\\b(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,})\\b'
    $'auth-header\t[Aa]uthorization:[[:space:]]*(Bearer|Basic)[[:space:]]+[A-Za-z0-9+/=_.-]{16,}'
    $'password-literal\t(password|passwd|pwd|secret|api[_-]?key|token)[[:space:]]*[:=][[:space:]]*["\x27][^"\x27]{6,}["\x27]'
    $'sshpass-literal\tsshpass[[:space:]]+-p[[:space:]]+["\x27]?[^"\x27$<[:space:]]'
    $'ipv4-address\t\\b(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\b'
)

# IPs that are always acceptable: loopback, unspecified, broadcast, and the
# RFC 5737 documentation ranges. Anything else (public OR private) flags —
# private addresses still leak internal topology.
BUILTIN_IP_ALLOW='^(0\.0\.0\.0|127\.[0-9]+\.[0-9]+\.[0-9]+|255\.255\.255\.255|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$'

# Values that are clearly placeholders, not real credentials.
PLACEHOLDER_VALUE='(^|[:=][[:space:]]*["\x27]?)(\$|\$\{|<|%|\{\{)|example|placeholder|changeme|dummy|xxxx|\*\*\*|your[-_]'

usage() {
    grep '^#   --' "$0" | sed 's/^# *//'
    exit 2
}

# --- collect candidate lines as "file:line:content" -------------------------
added_lines_from_diff() {
    # Unified zero-context diff -> "file:newline:content" for added lines.
    awk '
        /^\+\+\+ b\// { file = substr($0, 7); next }
        /^@@/ {
            split($3, a, ",");
            line = substr(a[1], 2) + 0;
            next
        }
        /^\+/ && !/^\+\+\+/ {
            printf "%s:%d:%s\n", file, line, substr($0, 2);
            line++;
            next
        }
        /^ / { line++ }
    '
}

collect() {
    case "$MODE" in
        staged) git diff --cached -U0 --no-color --diff-filter=ACM | added_lines_from_diff ;;
        diff)   git diff -U0 --no-color --diff-filter=ACM "$RANGE" | added_lines_from_diff ;;
        all)    git grep -nI -e '' -- "$REPO_ROOT" 2>/dev/null || true ;;
    esac
}

# --- allowlist ---------------------------------------------------------------
allowlisted() {
    local line="$1"
    [[ -f "$ALLOWLIST" ]] || return 1
    while IFS= read -r rule; do
        [[ -z "$rule" || "$rule" == \#* ]] && continue
        if grep -qE -- "$rule" <<< "$line"; then
            return 0
        fi
    done < "$ALLOWLIST"
    return 1
}

# --- main --------------------------------------------------------------------
MODE="staged"
RANGE=""
case "${1:---staged}" in
    --staged) MODE="staged" ;;
    --diff) MODE="diff"; RANGE="${2:?--diff requires a range like origin/main...HEAD}" ;;
    --all) MODE="all" ;;
    --install-hook)
        HOOK="$REPO_ROOT/.git/hooks/pre-commit"
        mkdir -p "$(dirname "$HOOK")"
        cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# Sensitive-data gate (installed by scripts/check-sensitive-data.sh --install-hook).
exec "$(git rev-parse --show-toplevel)/scripts/check-sensitive-data.sh" --staged
EOF
        chmod +x "$HOOK"
        echo "installed: $HOOK"
        echo "note: if 'git config core.hooksPath' points elsewhere, chain this script there."
        exit 0
        ;;
    -h|--help) usage ;;
    *) usage ;;
esac

CANDIDATES="$(collect || true)"
[[ -z "$CANDIDATES" ]] && { echo "sensitive-scan: nothing to scan"; exit 0; }

FINDINGS=0
for entry in "${PATTERNS[@]}"; do
    label="${entry%%$'\t'*}"
    pattern="${entry#*$'\t'}"
    matches="$(grep -E -- "$pattern" <<< "$CANDIDATES" || true)"
    [[ -z "$matches" ]] && continue
    while IFS= read -r m; do
        content="${m#*:*:}"
        # Per-label noise filters run before the shared allowlist.
        case "$label" in
            ipv4-address)
                ip="$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$content" | head -1)"
                [[ "$ip" =~ $BUILTIN_IP_ALLOW ]] && continue
                ;;
            password-literal|sshpass-literal)
                grep -qEi -- "$PLACEHOLDER_VALUE" <<< "$content" && continue
                ;;
        esac
        allowlisted "$m" && continue
        echo "SENSITIVE[$label] $m"
        FINDINGS=$((FINDINGS + 1))
    done <<< "$matches"
done

if [[ "$FINDINGS" -gt 0 ]]; then
    echo ""
    echo "sensitive-scan: $FINDINGS finding(s) — COMMIT REJECTED."
    echo "Redact the data (placeholder / environment variable) and re-run."
    echo "Legitimate hits: add a justified ERE to .github/sensitive-scan-allowlist.txt"
    exit 1
fi
echo "sensitive-scan: clean"
