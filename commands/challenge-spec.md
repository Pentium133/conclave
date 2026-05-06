---
description: Adversarial spec review. Invokes the spec-skeptic subagent to hunt 3am failure modes.
allowed-tools: Bash, Read, Task
---

# /challenge-spec

You are the entry point for the spec-skeptic stage. Wrapper-only: validate state, hand off to the `spec-skeptic` subagent.

## Resolve active project

1. Read `process/CURRENT`. If missing/empty, print «No active project. Run `/start <slug>` first.» and stop.
2. Verify `process/<slug>/STATE.md` exists; if not, print remediation and stop.

## Stage validation

Read the YAML frontmatter `stage:` field of `process/<slug>/STATE.md`. Allowed stage for `/challenge-spec`: `spec-approved`.

If the stage is anything else, refuse:

«Cannot run `/challenge-spec`: current stage is `<X>`, expected `spec-approved`. <Suggest correct command, e.g. `/interview` if stage is `intake`/`interview`, `/architect` if stage is `verdicts-applied`.>»

and stop.

## Hand off to subagent

Invoke the `spec-skeptic` subagent via the Task tool (`subagent_type: spec-skeptic`). Pass it a prompt with these absolute paths and instructions:

- `process/<slug>/spec.md` — read-only input. The skeptic must NOT modify it.
- `${CLAUDE_PLUGIN_ROOT}/templates/spec-review.template.md` — exact output structure.
- `process/<slug>/STATE.md` — the skeptic owns updating it on completion.

Tell the subagent: «You own writing `process/<slug>/spec-review.md` and updating `STATE.md` (set `stage: spec-reviewed`, tick the checkbox, update Artifacts, append log line). The slash command does not touch these files.»

## After return

Print to the developer:

«Skeptic verdict written to `process/<slug>/spec-review.md`. Read it, mark each objection accepted / rejected / deferred in your head or in the file, update `spec.md` with any accepted fixes, then either:
- if you applied changes: manually set `stage: verdicts-applied` in `STATE.md` and run `/architect`;
- if you accepted that no spec changes are needed: leave `stage: spec-reviewed`, append a log line «verdicts considered no-action-needed», and run `/architect`.»

Do NOT modify `STATE.md` from this command.
