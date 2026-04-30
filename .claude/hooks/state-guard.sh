#!/usr/bin/env bash
# state-guard.sh — PreToolUse hook for Claude Code.
#
# Validates that a Task subagent dispatch matches the project's current
# pipeline stage (process/<slug>/STATE.md). This is a belt-and-suspenders
# safety net layered ON TOP of the inline validation in the slash commands.
#
# Hook contract (Claude Code PreToolUse):
#   - Reads JSON payload on stdin: { tool_name, tool_input, ... }.
#   - To allow: exit 0 with empty stdout.
#   - To block: exit 0 with stdout JSON {"decision":"block","reason":"..."}.
#   - Non-zero exit is reserved for hook errors (we keep them rare).
#
# Behavior:
#   1. tool_name != Task              -> allow (pass-through).
#   2. subagent_type unmanaged        -> allow.
#   3. process/CURRENT missing/empty  -> allow (no active project).
#   4. process/<slug>/STATE.md missing -> block (orphan project).
#   5. stage from STATE.md frontmatter not in allowed list -> block.
#   6. otherwise                       -> allow.
#
# Allowed (subagent, stage) pairings:
#   interviewer  : intake, interview
#   spec-skeptic : spec-approved
#   architect    : verdicts-applied, spec-reviewed
#   arch-reviewer: arch-proposed
#   code-auditor : arch-reviewed, audit-done

set -u

# emit_block <reason>
# Emits {"decision":"block","reason":"..."} on stdout and exits 0.
emit_block() {
    local reason="$1"
    # Escape backslashes and double quotes for JSON.
    local escaped="${reason//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    exit 0
}

# allow: silent exit 0.
allow() {
    exit 0
}

# Read stdin (the hook payload). Use cat into a variable to be tolerant of
# missing/empty stdin.
INPUT="$(cat 2>/dev/null || true)"
if [[ -z "$INPUT" ]]; then
    allow
fi

# Parse fields with jq if available; otherwise fall back to grep.
if command -v jq >/dev/null 2>&1; then
    TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)"
    SUBAGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)"
else
    # Fallback heuristic — fragile, but better than nothing.
    TOOL_NAME="$(printf '%s' "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    SUBAGENT_TYPE="$(printf '%s' "$INPUT" | grep -o '"subagent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
fi

# Step 1: only the Task tool is gated.
if [[ "$TOOL_NAME" != "Task" ]]; then
    allow
fi

# Step 2: only managed subagents are gated.
case "$SUBAGENT_TYPE" in
    interviewer|spec-skeptic|architect|arch-reviewer|code-auditor) ;;
    *) allow ;;
esac

# Step 3: read process/CURRENT for active project slug.
if [[ ! -f "process/CURRENT" ]]; then
    allow
fi

CURRENT_SLUG="$(tr -d '[:space:]' < process/CURRENT 2>/dev/null || true)"
if [[ -z "$CURRENT_SLUG" ]]; then
    allow
fi

# Step 4: STATE.md must exist for the active project.
STATE_FILE="process/$CURRENT_SLUG/STATE.md"
if [[ ! -f "$STATE_FILE" ]]; then
    emit_block "STATE.md missing for project $CURRENT_SLUG (expected at $STATE_FILE). Run /start to bootstrap."
fi

# Step 5: extract `stage:` from YAML frontmatter (lines between leading `---`
# and the next `---`). Tolerant of leading/trailing whitespace.
STAGE="$(awk '
    BEGIN { in_fm = 0; n = 0 }
    /^---[[:space:]]*$/ {
        n++
        if (n == 1) { in_fm = 1; next }
        if (n == 2) { exit }
    }
    in_fm && /^[[:space:]]*stage[[:space:]]*:/ {
        sub(/^[[:space:]]*stage[[:space:]]*:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        # Strip surrounding quotes if any.
        gsub(/^["'\'']|["'\'']$/, "")
        print
        exit
    }
' "$STATE_FILE" 2>/dev/null || true)"

if [[ -z "$STAGE" ]]; then
    emit_block "could not extract 'stage:' from $STATE_FILE frontmatter"
fi

# Step 6: validate (subagent, stage) pairing.
ALLOWED=""
case "$SUBAGENT_TYPE" in
    interviewer)   ALLOWED="intake interview" ;;
    spec-skeptic)  ALLOWED="spec-approved" ;;
    architect)     ALLOWED="verdicts-applied spec-reviewed" ;;
    arch-reviewer) ALLOWED="arch-proposed" ;;
    code-auditor)  ALLOWED="arch-reviewed audit-done" ;;
esac

for s in $ALLOWED; do
    if [[ "$s" == "$STAGE" ]]; then
        allow
    fi
done

emit_block "subagent '$SUBAGENT_TYPE' is not allowed at stage '$STAGE' (project $CURRENT_SLUG). Allowed stages: $ALLOWED. Check process/$CURRENT_SLUG/STATE.md and run the appropriate slash command for the current stage."
