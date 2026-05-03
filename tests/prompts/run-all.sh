#!/usr/bin/env bash
# tests/prompts/run-all.sh — meta-driver for the prompt regression suite.
#
# Two modes:
#   - HEADLESS (default when stdin is not a TTY OR --headless flag passed):
#       Driver itself invokes `claude -p "/<command>" --dangerously-skip-permissions`
#       for fixtures 02 and 03. Fixture 01 is SKIPPED because /interview is a
#       multi-turn dialogue and `claude -p` is one-shot.
#   - INTERACTIVE (default when stdin is a TTY OR --interactive flag passed):
#       Original two-terminal flow — driver pauses, developer runs the slash
#       command in another `claude` session, returns and presses Enter. All 3
#       fixtures run.
#
# Usage:
#   bash tests/prompts/run-all.sh                # auto: TTY → interactive, no-TTY → headless
#   bash tests/prompts/run-all.sh --headless     # force headless, skip fixture 01
#   bash tests/prompts/run-all.sh --interactive  # force interactive, all 3 fixtures
#   bash tests/prompts/run-all.sh --no-cleanup   # leave process/<slug>/ for inspection
#   bash tests/prompts/run-all.sh --help         # usage
#
# Exit code: 0 if all RUN fixtures PASS, 1 if any FAIL.
# (Skipped fixtures do not count toward FAIL.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NO_CLEANUP=0
MODE_FLAG=""   # "", "headless", "interactive"

usage() {
    cat <<'EOF'
tests/prompts/run-all.sh — antisycophancy regression suite driver.

Three fixtures verify that subagent prompts in .claude/agents/ enforce their
antisycophancy mechanisms on adversarial inputs:
  01 evasive-developer    interviewer  vs evasive answers          (interactive only)
  02 soft-spec            spec-skeptic vs deliberately soft spec   (headless or interactive)
  03 plausible-adrs       arch-reviewer vs ADRs with hidden traps  (headless or interactive)

Modes:
  --headless     Driver invokes `claude -p "/<command>" --dangerously-skip-permissions`
                 for fixtures 02 and 03. Fixture 01 is SKIPPED (multi-turn dialogue
                 cannot be driven through `-p`). One-command flow, suitable for CI.
  --interactive  Driver pauses; you run the slash command in another `claude`
                 session, then press Enter. All 3 fixtures run.
  (auto)         If stdin is a TTY → interactive. Otherwise → headless.

Usage:
  bash tests/prompts/run-all.sh
  bash tests/prompts/run-all.sh --headless
  bash tests/prompts/run-all.sh --interactive
  bash tests/prompts/run-all.sh --no-cleanup
  bash tests/prompts/run-all.sh --help

Each fixture uses a unique slug (regression-<name>-<epoch>) to avoid colliding
with real projects in process/.

Prerequisites:
  - `claude` CLI installed (any mode).
  - Headless mode also needs working auth (ANTHROPIC_API_KEY env var or a
    pre-existing claude login).
  - `bash`, standard coreutils, `timeout` (coreutils on Linux; `gtimeout` on
    macOS via brew install coreutils — driver detects either).

Exit code:
  0 — all RUN fixtures PASS (skipped fixtures don't count as fail)
  1 — at least 1 fixture FAIL (or precondition missing)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --no-cleanup) NO_CLEANUP=1; shift ;;
        --headless) MODE_FLAG="headless"; shift ;;
        --interactive) MODE_FLAG="interactive"; shift ;;
        *) printf 'unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

# Decide effective mode.
if [[ -n "$MODE_FLAG" ]]; then
    MODE="$MODE_FLAG"
elif [[ -t 0 ]]; then
    MODE="interactive"
else
    MODE="headless"
fi

# Detect timeout binary (coreutils `timeout` on Linux; macOS often only has it
# via `gtimeout` from `brew install coreutils`).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
fi

if [[ "$MODE" == "headless" ]]; then
    if ! command -v claude >/dev/null 2>&1; then
        printf 'error: headless mode requires `claude` CLI on PATH but none found.\n' >&2
        exit 1
    fi
    if [[ -z "$TIMEOUT_BIN" ]]; then
        printf 'warning: no `timeout`/`gtimeout` found; headless claude -p calls\n' >&2
        printf '         will run without a hard wallclock cap. Install coreutils\n' >&2
        printf '         (brew install coreutils on macOS) for protection.\n\n' >&2
    fi
fi

pause_for_user() {
    local msg="$1"
    printf '\n>>> %s\n' "$msg"
    printf '>>> Press Enter when ready (or Ctrl-C to abort).\n'
    # shellcheck disable=SC2034
    read -r _UNUSED || true
}

# run_claude_p <slash-command> <log-file>
# Wraps claude -p in a 5-min timeout if available. Returns claude's exit code,
# or 124 if the timeout fired.
run_claude_p() {
    local cmd="$1" log="$2"
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" 300s claude -p "$cmd" --dangerously-skip-permissions \
            >"$log" 2>&1
        return $?
    else
        claude -p "$cmd" --dangerously-skip-permissions >"$log" 2>&1
        return $?
    fi
}

EPOCH="$(date '+%s')"
SLUG_01="regression-evasive-$EPOCH"
SLUG_02="regression-softspec-$EPOCH"
SLUG_03="regression-adrs-$EPOCH"

PASS_FIXTURES=0
FAIL_FIXTURES=0
SKIP_FIXTURES=0
FAIL_NAMES=()
SKIP_NAMES=()

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

skip() {
    local name="$1" reason="$2"
    SKIP_FIXTURES=$((SKIP_FIXTURES + 1))
    SKIP_NAMES+=("$name")
    printf '\n=== fixture %s: SKIP — %s ===\n' "$name" "$reason"
}

cleanup_slug() {
    local slug="$1"
    rm -rf "$REPO_ROOT/process/$slug"
    if [[ -f "$REPO_ROOT/process/CURRENT" ]]; then
        local cur
        cur="$(tr -d '[:space:]' < "$REPO_ROOT/process/CURRENT" 2>/dev/null || true)"
        [[ "$cur" == "$slug" ]] && : > "$REPO_ROOT/process/CURRENT"
    fi
    printf '(cleaned up process/%s)\n' "$slug"
}

# --- header ---
printf '======================================================================\n'
printf '  prompt regression suite — antisycophancy invariants\n'
printf '======================================================================\n'
printf '\nMode: %s' "$MODE"
if [[ -n "$MODE_FLAG" ]]; then
    printf ' (forced via --%s)\n' "$MODE_FLAG"
elif [[ -t 0 ]]; then
    printf ' (auto: stdin is a TTY)\n'
else
    printf ' (auto: stdin is not a TTY — likely CI)\n'
fi
printf '\nThis suite verifies that subagent prompts in .claude/agents/ actually\n'
printf 'enforce their antisycophancy mechanisms on adversarial inputs.\n\n'
printf 'Test slugs:\n'
printf '  01 evasive-developer  : %s\n' "$SLUG_01"
printf '  02 soft-spec          : %s\n' "$SLUG_02"
printf '  03 plausible-adrs     : %s\n' "$SLUG_03"
if [[ "$NO_CLEANUP" -eq 1 ]]; then
    printf '\nCleanup: OFF (--no-cleanup) — process/<slug>/ will be preserved.\n'
else
    printf '\nCleanup: ON — test artifacts removed after each fixture.\n'
fi

# ============================================================================
# Fixture 01: evasive developer
# ============================================================================
printf '\n----------------------------------------------------------------------\n'
printf '  fixture 01: evasive developer (interviewer regression)\n'
printf -- '----------------------------------------------------------------------\n'

if [[ "$MODE" == "headless" ]]; then
    skip "01 evasive-developer" \
         "requires interactive dialogue with /interview; not driveable via claude -p. Run with --interactive to include."
else
    pause_for_user "Ready to start fixture 01?"
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

    [[ "$NO_CLEANUP" -eq 0 ]] && cleanup_slug "$SLUG_01"
fi

# ============================================================================
# Fixture 02: soft spec
# ============================================================================
printf '\n----------------------------------------------------------------------\n'
printf '  fixture 02: soft spec (spec-skeptic regression)\n'
printf -- '----------------------------------------------------------------------\n'
printf '\nSetting up process/%s with the soft-spec.md fixture...\n' "$SLUG_02"
bash "$SCRIPT_DIR/02-soft-spec/assert.sh" "$SLUG_02" --setup-only

if [[ "$MODE" == "headless" ]]; then
    LOG02="$REPO_ROOT/process/$SLUG_02/claude-p.log"
    printf '\nInvoking: claude -p "/challenge-spec" --dangerously-skip-permissions\n'
    printf '         (timeout: 300s; log: %s)\n' "$LOG02"
    set +e
    run_claude_p "/challenge-spec" "$LOG02"
    CLAUDE_EXIT=$?
    set -e
    if [[ "$CLAUDE_EXIT" -eq 124 ]]; then
        printf '\n!!! claude -p timed out after 300s — likely auth issue or model unavailable.\n' >&2
        printf '    last 20 log lines:\n' >&2
        tail -n 20 "$LOG02" >&2 || true
        record "02 soft-spec" 1
    elif [[ "$CLAUDE_EXIT" -ne 0 ]]; then
        printf '\n!!! claude -p exited with code %d.\n' "$CLAUDE_EXIT" >&2
        printf '    last 20 log lines:\n' >&2
        tail -n 20 "$LOG02" >&2 || true
        # Still try assertions: claude may have produced the artifact even on a non-zero
        # exit (e.g. some warning at shutdown).
        set +e
        bash "$SCRIPT_DIR/02-soft-spec/assert.sh" "$SLUG_02" --assert-only
        F2_STATUS=$?
        set -e
        record "02 soft-spec" "$F2_STATUS"
    else
        printf 'claude -p exited 0; running assertions.\n'
        set +e
        bash "$SCRIPT_DIR/02-soft-spec/assert.sh" "$SLUG_02" --assert-only
        F2_STATUS=$?
        set -e
        record "02 soft-spec" "$F2_STATUS"
    fi
else
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
fi

[[ "$NO_CLEANUP" -eq 0 ]] && cleanup_slug "$SLUG_02"

# ============================================================================
# Fixture 03: plausible ADRs
# ============================================================================
printf '\n----------------------------------------------------------------------\n'
printf '  fixture 03: plausible adrs (arch-reviewer regression)\n'
printf -- '----------------------------------------------------------------------\n'
printf '\nSetting up process/%s with input-spec.md and plausible ADRs...\n' "$SLUG_03"
bash "$SCRIPT_DIR/03-plausible-adrs/assert.sh" "$SLUG_03" --setup-only

if [[ "$MODE" == "headless" ]]; then
    LOG03="$REPO_ROOT/process/$SLUG_03/claude-p.log"
    printf '\nInvoking: claude -p "/review-arch" --dangerously-skip-permissions\n'
    printf '         (timeout: 300s; log: %s)\n' "$LOG03"
    set +e
    run_claude_p "/review-arch" "$LOG03"
    CLAUDE_EXIT=$?
    set -e
    if [[ "$CLAUDE_EXIT" -eq 124 ]]; then
        printf '\n!!! claude -p timed out after 300s — likely auth issue or model unavailable.\n' >&2
        printf '    last 20 log lines:\n' >&2
        tail -n 20 "$LOG03" >&2 || true
        record "03 plausible-adrs" 1
    elif [[ "$CLAUDE_EXIT" -ne 0 ]]; then
        printf '\n!!! claude -p exited with code %d.\n' "$CLAUDE_EXIT" >&2
        printf '    last 20 log lines:\n' >&2
        tail -n 20 "$LOG03" >&2 || true
        set +e
        bash "$SCRIPT_DIR/03-plausible-adrs/assert.sh" "$SLUG_03" --assert-only
        F3_STATUS=$?
        set -e
        record "03 plausible-adrs" "$F3_STATUS"
    else
        printf 'claude -p exited 0; running assertions.\n'
        set +e
        bash "$SCRIPT_DIR/03-plausible-adrs/assert.sh" "$SLUG_03" --assert-only
        F3_STATUS=$?
        set -e
        record "03 plausible-adrs" "$F3_STATUS"
    fi
else
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
fi

[[ "$NO_CLEANUP" -eq 0 ]] && cleanup_slug "$SLUG_03"

# --- summary ---
TOTAL_RUN=$((PASS_FIXTURES + FAIL_FIXTURES))
printf '\n======================================================================\n'
printf '  SUITE SUMMARY: %d/%d fixtures passed' "$PASS_FIXTURES" "$TOTAL_RUN"
if [[ "$SKIP_FIXTURES" -gt 0 ]]; then
    printf ' (%d skipped)' "$SKIP_FIXTURES"
fi
printf '\n'
printf '======================================================================\n'
if [[ "$SKIP_FIXTURES" -gt 0 ]]; then
    printf 'skipped fixtures:\n'
    for n in "${SKIP_NAMES[@]}"; do
        printf '  - %s\n' "$n"
    done
fi
if [[ "$FAIL_FIXTURES" -gt 0 ]]; then
    printf 'failed fixtures:\n'
    for n in "${FAIL_NAMES[@]}"; do
        printf '  - %s\n' "$n"
    done
    exit 1
fi
exit 0
