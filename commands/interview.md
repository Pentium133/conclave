---
description: Run the requirements interview. Invokes the interviewer subagent to grow spec.md.
allowed-tools: Bash, Read, Edit, Write, Task
---

# /interview

You are the entry point for the requirements-gathering stage. Your job is wrapper-only: validate the pipeline state, prepare `spec.md`, mark `STATE.md` `stage: interview`, then hand control to the `interviewer` subagent.

## Resolve active project

1. Read `process/CURRENT`. If missing/empty, print «No active project. Run `/start <slug>` first.» and stop.
2. Verify `process/<slug>/STATE.md` exists; if not, print remediation and stop.

## Stage validation

Read the YAML frontmatter `stage:` field of `process/<slug>/STATE.md`. Allowed stages for `/interview`: `intake`, `interview`.

If the stage is anything else, refuse with:

«Cannot run `/interview`: current stage is `<X>`, expected `intake` or `interview`. Run `/status` to see what to do next.»

and stop.

## Pre-flight

1. If `process/<slug>/spec.md` does not exist:
   - Copy `${CLAUDE_PLUGIN_ROOT}/templates/spec.template.md` → `process/<slug>/spec.md`.
   - Replace the `# Spec: <slug>` heading with `# Spec: <slug>`.
2. If the current stage is `intake`:
   - In `STATE.md`, replace `stage: intake` with `stage: interview`.
   - Tick the `interview` checkbox: `- [ ] interview — <YYYY-MM-DD>` → `- [x] interview — <today>`.
   - Update `last_updated:` to today.
   - Append to `## Log`: `- <today HH:MM> — interview started`.
   - Set `Pending human action` to «Answer the interviewer's questions until every NFR slot is filled.»

## Hand off to subagent

Invoke the `interviewer` subagent via the Task tool (`subagent_type: interviewer`). Pass it a prompt with these absolute paths and instructions:

- `process/<slug>/spec.md` — working spec, the agent grows it.
- `process/<slug>/STATE.md` — the agent owns the final transition to `stage: spec-approved` once the developer signs off in §Approval.
- `${CLAUDE_PLUGIN_ROOT}/templates/spec.template.md` — read once at start.

Tell the subagent: «You own updates to `spec.md`. The slash command has already set `stage: interview`. When the developer writes `approve` and a date in §Approval, you set `stage: spec-approved`, tick the corresponding checkbox, update Artifacts, and append a log line.»

After the subagent returns control, do not modify `STATE.md` from this command — the subagent already did. Just print a one-line summary to the user.
