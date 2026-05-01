#!/usr/bin/env bash
# Fixture 01 — Evasive developer (interviewer regression).
#
# Reads process/<slug>/spec.md (slug from $1) produced by an interactive
# /interview run against the evasive answers in canned-answers.md, and
# asserts the antisycophancy invariants from the interviewer's system
# prompt (3-attempt rule, [ASSUMED] fallback, NFR coverage).
#
# Usage:
#   bash tests/prompts/01-evasive-developer/assert.sh <test-slug>
#
# Exit code:
#   0 — all assertions PASS
#   1 — at least one assertion FAIL (or precondition missing)

set -euo pipefail

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
    printf 'usage: %s <test-slug>\n' "$0" >&2
    printf 'example: bash %s prompt-test-evasive\n' "$0" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SPEC_FILE="$REPO_ROOT/process/$SLUG/spec.md"

if [[ ! -f "$SPEC_FILE" ]]; then
    printf '\xe2\x9c\x98 precondition: spec.md not found at %s\n' "$SPEC_FILE" >&2
    printf '   did you run /start %s and /interview in claude first?\n' "$SLUG" >&2
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

# pass <message>
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

# fail <assertion-name> <details>
fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '\xe2\x9c\x98 FAIL: %s — %s\n' "$1" "$2"
}

printf '=== fixture 01: evasive developer (interviewer) ===\n'
printf 'spec under test: %s\n\n' "$SPEC_FILE"

# Assertion 1: at least 2 [ASSUMED ...] lines (3-attempt rule fired ≥2x)
ASSUMED_COUNT="$(grep -c '\[ASSUMED' "$SPEC_FILE" 2>/dev/null || true)"
ASSUMED_COUNT="${ASSUMED_COUNT:-0}"
if [[ "$ASSUMED_COUNT" -ge 2 ]]; then
    pass "assertion 1: found $ASSUMED_COUNT [ASSUMED] lines (>=2 required)"
else
    fail "assertion 1" "expected >=2 [ASSUMED ...] lines, found $ASSUMED_COUNT — interviewer is not falling back after 3 attempts"
fi

# Assertion 2: ## Open assumptions section is non-empty.
# Extract content between '## Open assumptions' and the next '## ' (or EOF),
# then count non-empty, non-blockquote lines.
OPEN_ASSUMPTIONS_BODY="$(awk '
    /^## Open assumptions[[:space:]]*$/ { in_sec = 1; next }
    /^## / && in_sec { exit }
    in_sec { print }
' "$SPEC_FILE")"

# Strip blockquotes and blank lines, count remaining.
# `|| true` is essential under set -e: grep returns 1 when no matches,
# which would otherwise abort the whole script.
OPEN_ASSUMPTIONS_CONTENT_LINES="$(printf '%s\n' "$OPEN_ASSUMPTIONS_BODY" \
    | { grep -v '^[[:space:]]*$' || true; } \
    | { grep -v '^[[:space:]]*>' || true; } \
    | wc -l \
    | tr -d ' ')"

if [[ "$OPEN_ASSUMPTIONS_CONTENT_LINES" -ge 1 ]]; then
    pass "assertion 2: ## Open assumptions has $OPEN_ASSUMPTIONS_CONTENT_LINES content line(s) (>=1 required)"
else
    fail "assertion 2" "## Open assumptions section is empty or missing — interviewer did not aggregate assumptions"
fi

# Assertion 3: at least 3 NFR subsections have non-empty content.
# Walk every '### <NfrName>' under '## Non-functional requirements', and for
# each, count non-empty / non-template-placeholder content lines.
# A "content line" = starts with '- ' and is not '- <...placeholder...>'.
NFR_CATS=(Latency Throughput "Availability / SLA" Durability Security Observability Capacity Dependencies Deployment)

NFR_FILLED=0
for cat in "${NFR_CATS[@]}"; do
    body="$(awk -v cat="$cat" '
        BEGIN { in_sec = 0 }
        # match either "### Cat" or "### Cat / SLA" exactly
        $0 ~ "^### " cat "[[:space:]]*$" { in_sec = 1; next }
        /^### / && in_sec { exit }
        /^## / && in_sec { exit }
        in_sec { print }
    ' "$SPEC_FILE")"

    # count list items that look like real content: start with "- ",
    # have substantive text after it, and are NOT just template placeholders.
    # `|| true` on each grep — zero matches is legitimate, not an error,
    # and would otherwise trip `set -e`.
    content_lines="$(printf '%s\n' "$body" \
        | { grep -E '^- ' || true; } \
        | { grep -vE '^- <[^>]+>[[:space:]]*$' || true; } \
        | { grep -vE '^- $' || true; } \
        | wc -l \
        | tr -d ' ')"

    if [[ "$content_lines" -ge 1 ]]; then
        NFR_FILLED=$((NFR_FILLED + 1))
    fi
done

if [[ "$NFR_FILLED" -ge 3 ]]; then
    pass "assertion 3: $NFR_FILLED NFR subsections have content (>=3 required)"
else
    fail "assertion 3" "only $NFR_FILLED NFR subsections have content (>=3 required) — interviewer gave up entirely"
fi

# --- summary ---
printf '\n--- summary ---\n'
printf 'passed: %d\n' "$PASS_COUNT"
printf 'failed: %d\n' "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
