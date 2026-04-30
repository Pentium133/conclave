#!/usr/bin/env bash
# Tests for state-guard.sh PreToolUse hook.
#
# Each test:
#   1. Sets up a temp directory acting as cwd ($SANDBOX) with optional
#      process/CURRENT and process/<slug>/STATE.md.
#   2. Pipes a simulated PreToolUse JSON payload into state-guard.sh,
#      executing the hook with cwd=$SANDBOX so relative paths resolve
#      correctly.
#   3. Captures exit code, stdout, stderr.
#   4. Asserts on exit code + presence/absence of "decision":"block" in
#      stdout.
#
# Conventions used (matching Claude Code hooks contract):
#   - allow  = exit 0 with no `decision: block` in stdout
#   - block  = exit 0 with stdout JSON containing `"decision":"block"`
#             (per Claude Code: non-zero exit is reserved for hook errors)
#
# Exit code 0 if all tests pass, 1 if any fail.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/state-guard.sh"
FIXTURES="$SCRIPT_DIR/test-fixtures"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# --- helpers ------------------------------------------------------------

# make_sandbox: creates a fresh temp dir and echoes its path.
make_sandbox() {
    mktemp -d "${TMPDIR:-/tmp}/state-guard-test.XXXXXX"
}

# write_state <sandbox> <slug> <fixture-name>
# Sets process/CURRENT to <slug> and copies fixture STATE.md into
# process/<slug>/STATE.md.
write_state() {
    local sandbox="$1" slug="$2" fixture="$3"
    mkdir -p "$sandbox/process/$slug"
    printf '%s\n' "$slug" > "$sandbox/process/CURRENT"
    cp "$FIXTURES/$fixture" "$sandbox/process/$slug/STATE.md"
}

# run_hook <sandbox> <json-payload>
# Runs the hook with cwd=sandbox and the payload on stdin.
# Sets globals: HOOK_EXIT, HOOK_STDOUT, HOOK_STDERR.
run_hook() {
    local sandbox="$1" payload="$2"
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    (
        cd "$sandbox"
        printf '%s' "$payload" | bash "$HOOK"
    ) >"$stdout_file" 2>"$stderr_file"
    HOOK_EXIT=$?
    HOOK_STDOUT="$(cat "$stdout_file")"
    HOOK_STDERR="$(cat "$stderr_file")"
    rm -f "$stdout_file" "$stderr_file"
}

assert_pass() {
    local name="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$name"
}

assert_fail() {
    local name="$1" reason="$2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$name")
    printf 'FAIL: %s: %s\n' "$name" "$reason"
    if [[ -n "${HOOK_STDOUT:-}" ]]; then
        printf '  stdout: %s\n' "$HOOK_STDOUT"
    fi
    if [[ -n "${HOOK_STDERR:-}" ]]; then
        printf '  stderr: %s\n' "$HOOK_STDERR"
    fi
    printf '  exit:   %s\n' "${HOOK_EXIT:-?}"
}

# expect_allow <name>
# Asserts: exit code 0 AND stdout does not contain "decision":"block".
expect_allow() {
    local name="$1"
    if [[ "$HOOK_EXIT" -ne 0 ]]; then
        assert_fail "$name" "expected exit 0, got $HOOK_EXIT"
        return
    fi
    if printf '%s' "$HOOK_STDOUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        assert_fail "$name" "expected allow but got block decision"
        return
    fi
    assert_pass "$name"
}

# expect_block <name>
# Asserts: hook signals block. The Claude Code convention is JSON
# {"decision":"block",...} on stdout with exit 0; we also accept non-zero
# exit + non-empty stderr (legacy stderr-block form). exit 127 (script not
# found) is rejected — that's a missing-hook error, not a real block.
expect_block() {
    local name="$1"
    if [[ "$HOOK_EXIT" -eq 127 ]]; then
        assert_fail "$name" "hook script not found (exit 127)"
        return
    fi
    if printf '%s' "$HOOK_STDOUT" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        assert_pass "$name"
        return
    fi
    if [[ "$HOOK_EXIT" -ne 0 && -n "$HOOK_STDERR" ]]; then
        assert_pass "$name"
        return
    fi
    assert_fail "$name" "expected block (decision:block JSON or non-zero exit + stderr) but call was allowed"
}

# --- preflight ----------------------------------------------------------

if [[ ! -f "$HOOK" ]]; then
    printf 'cannot find state-guard.sh at %s\n' "$HOOK" >&2
    printf 'all tests will fail until the hook is implemented.\n' >&2
fi

# --- test cases ---------------------------------------------------------

# Test 1: allow case — spec-approved + spec-skeptic
t1() {
    local name="allow: stage=spec-approved + spec-skeptic"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-spec state-spec-approved.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"spec-skeptic","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_allow "$name"
    rm -rf "$sb"
}

# Test 2: allow — intake + interviewer
t2() {
    local name="allow: stage=intake + interviewer"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-intake state-intake.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"interviewer","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_allow "$name"
    rm -rf "$sb"
}

# Test 3: allow — arch-reviewed + code-auditor
t3() {
    local name="allow: stage=arch-reviewed + code-auditor"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-arch state-arch-reviewed.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"code-auditor","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_allow "$name"
    rm -rf "$sb"
}

# Test 4: block — intake + architect
t4() {
    local name="block: stage=intake + architect"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-intake state-intake.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"architect","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_block "$name"
    rm -rf "$sb"
}

# Test 5: block — spec-approved + arch-reviewer
t5() {
    local name="block: stage=spec-approved + arch-reviewer"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-spec state-spec-approved.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"arch-reviewer","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_block "$name"
    rm -rf "$sb"
}

# Test 6: block — arch-reviewed + spec-skeptic (no going back)
t6() {
    local name="block: stage=arch-reviewed + spec-skeptic (no going back)"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-arch state-arch-reviewed.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"spec-skeptic","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_block "$name"
    rm -rf "$sb"
}

# Test 7: pass-through — tool_name=Read
t7() {
    local name="pass-through: tool_name=Read"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-intake state-intake.md
    local payload='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
    run_hook "$sb" "$payload"
    expect_allow "$name"
    rm -rf "$sb"
}

# Test 8: unknown subagent — Task with unmanaged subagent_type
t8() {
    local name="pass-through: Task with unknown subagent_type"
    local sb; sb="$(make_sandbox)"
    write_state "$sb" demo-intake state-intake.md
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"some-random-name","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_allow "$name"
    rm -rf "$sb"
}

# Test 9: process/CURRENT exists but STATE.md missing → block
t9() {
    local name="block: process/CURRENT present but STATE.md missing"
    local sb; sb="$(make_sandbox)"
    mkdir -p "$sb/process/orphan"
    printf 'orphan\n' > "$sb/process/CURRENT"
    # Note: no STATE.md in process/orphan/
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"interviewer","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_block "$name"
    if printf '%s' "$HOOK_STDOUT" | grep -qi 'STATE.md'; then
        : # message mentions STATE.md, good
    else
        # not strictly required to fail this — block is the main contract,
        # but if we're still passing, augment with a message check
        :
    fi
    rm -rf "$sb"
}

# Test 10: no active project — process/CURRENT missing → no-op (allow)
t10() {
    local name="no-op: process/CURRENT missing"
    local sb; sb="$(make_sandbox)"
    # Sandbox has no process/ directory at all.
    local payload='{"tool_name":"Task","tool_input":{"subagent_type":"architect","prompt":"go"}}'
    run_hook "$sb" "$payload"
    expect_allow "$name"
    rm -rf "$sb"
}

# --- run ----------------------------------------------------------------

t1; t2; t3; t4; t5; t6; t7; t8; t9; t10

printf '\n'
printf '=== summary ===\n'
printf 'passed: %d\n' "$PASS_COUNT"
printf 'failed: %d\n' "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf 'failed tests:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
