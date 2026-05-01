#!/usr/bin/env bash
# tests/prompts/run-all.sh — meta-driver for the prompt regression suite.
#
# Runs all three antisycophancy fixtures in sequence. Each fixture needs the
# developer to switch to a `claude` session in another window and run the
# corresponding slash command (/interview, /challenge-spec, /review-arch),
# then come back here and press Enter so the assertion phase runs.
#
# Usage:
#   bash tests/prompts/run-all.sh                # interactive mode
#   bash tests/prompts/run-all.sh --no-cleanup   # leave process/<slug>/ for inspection
#   bash tests/prompts/run-all.sh --help         # usage
#
# Exit code: 0 if all 3 fixtures PASS, 1 if any FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NO_CLEANUP=0

usage() {
    cat <<'EOF'
tests/prompts/run-all.sh — antisycophancy regression suite driver.

Three fixtures run in sequence:
  01 evasive-developer    interviewer  vs evasive answers
  02 soft-spec            spec-skeptic vs deliberately soft spec.md
  03 plausible-adrs       arch-reviewer vs ADRs with hidden ops traps

Each fixture is interactive: the driver pauses, prints the slash command to
run in your `claude` session, waits for you to come back and press Enter,
then runs assertion checks against the artifact the agent wrote.

Usage:
  bash tests/prompts/run-all.sh                # interactive (default cleanup ON)
  bash tests/prompts/run-all.sh --no-cleanup   # leave process/<slug>/ for inspection
  bash tests/prompts/run-all.sh --help         # this message

Each fixture uses a unique slug (regression-<name>-<epoch>) to avoid
colliding with real projects in process/.

Prerequisites:
  - `claude` CLI installed and a session open in another terminal.
  - working from repo root (or anywhere — paths are absolute).
  - `bash` and standard coreutils.

Exit code:
  0 — all 3 fixtures PASS
  1 — at least 1 fixture FAIL (or precondition missing)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --no-cleanup) NO_CLEANUP=1; shift ;;
        *) printf 'unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

pause_for_user() {
    local msg="$1"
    printf '\n>>> %s\n' "$msg"
    printf '>>> Press Enter when ready (or Ctrl-C to abort).\n'
    # shellcheck disable=SC2034
    read -r _UNUSED || true
}

EPOCH="$(date '+%s')"
SLUG_01="regression-evasive-$EPOCH"
SLUG_02="regression-softspec-$EPOCH"
SLUG_03="regression-adrs-$EPOCH"

PASS_FIXTURES=0
FAIL_FIXTURES=0
FAIL_NAMES=()

record() {
    local name="$1" status="$2"
    if [[ "$status" -eq 0 ]]; then
        PASS_FIXTURES=$((PASS_FIXTURES + 1))
        printf '\n=== fixture %s: PASS ===\n' "$name"
    else
        FAIL_FIXTURES=$((FAIL_FIXTURES + 1))
        FAIL_NAMES+=("$name")
        printf '\n=== fixture %s: FAIL ===\n' "$name"
    fi
}

# --- header ---
printf '======================================================================\n'
printf '  prompt regression suite — antisycophancy invariants\n'
printf '======================================================================\n'
printf '\nThis suite verifies that subagent prompts in .claude/agents/ actually\n'
printf 'enforce their antisycophancy mechanisms (3-attempt rule, two-pass\n'
printf 'self-rating, per-ADR disagree-flag) on adversarial inputs.\n\n'
printf 'Three fixtures will run, each requires you to switch to your claude\n'
printf 'session and execute one slash command. Test slugs:\n'
printf '  01 evasive-developer  : %s\n' "$SLUG_01"
printf '  02 soft-spec          : %s\n' "$SLUG_02"
printf '  03 plausible-adrs     : %s\n' "$SLUG_03"
if [[ "$NO_CLEANUP" -eq 1 ]]; then
    printf '\nCleanup: OFF (--no-cleanup) — process/<slug>/ will be preserved.\n'
else
    printf '\nCleanup: ON — test artifacts removed after each fixture.\n'
fi

pause_for_user "Ready to start fixture 01?"

# --- fixture 01: evasive developer ---
printf '\n----------------------------------------------------------------------\n'
printf '  fixture 01: evasive developer (interviewer regression)\n'
printf '----------------------------------------------------------------------\n'
cat <<EOF

In your claude session, run:
  /start $SLUG_01
  /interview

Then copy-paste evasive replies from
  $SCRIPT_DIR/01-evasive-developer/canned-answers.md
one at a time as the interviewer asks questions. Skip writing 'approve' —
let the interview close on its own (or stop after ~15 exchanges).
EOF
pause_for_user "Done with /interview for $SLUG_01? Press Enter to run assertions."

set +e
bash "$SCRIPT_DIR/01-evasive-developer/assert.sh" "$SLUG_01"
F1_STATUS=$?
set -e
record "01 evasive-developer" "$F1_STATUS"

if [[ "$NO_CLEANUP" -eq 0 ]]; then
    rm -rf "$REPO_ROOT/process/$SLUG_01"
    if [[ -f "$REPO_ROOT/process/CURRENT" ]]; then
        CUR="$(tr -d '[:space:]' < "$REPO_ROOT/process/CURRENT" 2>/dev/null || true)"
        [[ "$CUR" == "$SLUG_01" ]] && : > "$REPO_ROOT/process/CURRENT"
    fi
    printf '(cleaned up process/%s)\n' "$SLUG_01"
fi

# --- fixture 02: soft spec ---
printf '\n----------------------------------------------------------------------\n'
printf '  fixture 02: soft spec (spec-skeptic regression)\n'
printf '----------------------------------------------------------------------\n'
printf '\nSetting up process/%s with the soft-spec.md fixture...\n' "$SLUG_02"
bash "$SCRIPT_DIR/02-soft-spec/assert.sh" "$SLUG_02" --setup-only

cat <<EOF

In your claude session, run:
  /challenge-spec

(state-guard already permits this because stage=spec-approved.)
Wait for spec-skeptic to write process/$SLUG_02/spec-review.md.
EOF
pause_for_user "Done with /challenge-spec? Press Enter to run assertions."

set +e
bash "$SCRIPT_DIR/02-soft-spec/assert.sh" "$SLUG_02" --assert-only
F2_STATUS=$?
set -e
record "02 soft-spec" "$F2_STATUS"

if [[ "$NO_CLEANUP" -eq 0 ]]; then
    rm -rf "$REPO_ROOT/process/$SLUG_02"
    if [[ -f "$REPO_ROOT/process/CURRENT" ]]; then
        CUR="$(tr -d '[:space:]' < "$REPO_ROOT/process/CURRENT" 2>/dev/null || true)"
        [[ "$CUR" == "$SLUG_02" ]] && : > "$REPO_ROOT/process/CURRENT"
    fi
    printf '(cleaned up process/%s)\n' "$SLUG_02"
fi

# --- fixture 03: plausible adrs ---
printf '\n----------------------------------------------------------------------\n'
printf '  fixture 03: plausible adrs (arch-reviewer regression)\n'
printf '----------------------------------------------------------------------\n'
printf '\nSetting up process/%s with input-spec.md and plausible ADRs...\n' "$SLUG_03"
bash "$SCRIPT_DIR/03-plausible-adrs/assert.sh" "$SLUG_03" --setup-only

cat <<EOF

In your claude session, run:
  /review-arch

(state-guard already permits this because stage=arch-proposed.)
Wait for arch-reviewer to write process/$SLUG_03/arch-review.md.
EOF
pause_for_user "Done with /review-arch? Press Enter to run assertions."

set +e
bash "$SCRIPT_DIR/03-plausible-adrs/assert.sh" "$SLUG_03" --assert-only
F3_STATUS=$?
set -e
record "03 plausible-adrs" "$F3_STATUS"

if [[ "$NO_CLEANUP" -eq 0 ]]; then
    rm -rf "$REPO_ROOT/process/$SLUG_03"
    if [[ -f "$REPO_ROOT/process/CURRENT" ]]; then
        CUR="$(tr -d '[:space:]' < "$REPO_ROOT/process/CURRENT" 2>/dev/null || true)"
        [[ "$CUR" == "$SLUG_03" ]] && : > "$REPO_ROOT/process/CURRENT"
    fi
    printf '(cleaned up process/%s)\n' "$SLUG_03"
fi

# --- summary ---
TOTAL=$((PASS_FIXTURES + FAIL_FIXTURES))
printf '\n======================================================================\n'
printf '  SUITE SUMMARY: %d/%d fixtures passed\n' "$PASS_FIXTURES" "$TOTAL"
printf '======================================================================\n'
if [[ "$FAIL_FIXTURES" -gt 0 ]]; then
    printf 'failed fixtures:\n'
    for n in "${FAIL_NAMES[@]}"; do
        printf '  - %s\n' "$n"
    done
    exit 1
fi
exit 0
