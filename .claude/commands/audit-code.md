---
description: Post-implementation audit. Invokes the code-auditor subagent on the shipped code.
argument-hint: <path-to-code-or-dir> [more-paths...]
allowed-tools: Bash, Read, Task
---

# /audit-code

Wrapper-only: validate state, hand off to the `code-auditor` subagent.

## Argument

`$ARGUMENTS` is one or more paths (files or directories) to the shipped code. If `$ARGUMENTS` is empty, refuse:

«`/audit-code` requires at least one code path. Usage: `/audit-code <path-to-code-or-dir> [more-paths...]`.»

and stop. Otherwise treat `$ARGUMENTS` as a whitespace-separated list of paths to forward to the subagent. Do not validate that the paths exist — the auditor will surface that as evidence (a missing path is itself a finding).

## Resolve active project

1. Read `process/CURRENT`. If missing/empty, print «No active project. Run `/start <slug>` first.» and stop.
2. Verify `process/<slug>/STATE.md` exists; if not, print remediation and stop.

## Stage validation

Read the YAML frontmatter `stage:` field of `process/<slug>/STATE.md`. Allowed stages: `arch-reviewed`, `implemented`, `audit-done`.

The `implemented` stage is the natural follow-up after `/implement`. The `audit-done` stage is allowed so the developer can re-audit after fixing findings. The `arch-reviewed` stage is also allowed for the case where the developer skipped `/implement` and shipped code outside the pipeline.

If the stage is anything else, refuse:

«Cannot run `/audit-code`: current stage is `<X>`, expected `arch-reviewed`, `implemented`, or `audit-done`. Run `/status` to see what to do next.»

and stop.

## Hand off to subagent

Invoke the `code-auditor` subagent via the Task tool (`subagent_type: code-auditor`). Pass it a prompt with these inputs:

- `process/<slug>/spec.md` — every FR-N / NFR-KIND-N must be classified.
- `process/<slug>/adr/*.md` — every ADR must be classified (pass the glob; the auditor will expand it via Glob).
- Code paths from `$ARGUMENTS` — the working tree to audit.
- `docs/templates/post-review.template.md` — exact output structure.
- `process/<slug>/STATE.md` — the subagent owns updating it.

Tell the subagent: «You own writing `process/<slug>/post-review.md` and updating `STATE.md` (set `stage: audit-done`, tick checkbox, update Artifacts, append a log line including findings count by severity). The slash command does not touch these files. You are read-only on code; do not modify it.»

## After return

Read `process/<slug>/post-review.md` and summarise to the developer:

- Final verdict (`ship` / `fix-required` / `reject`).
- Findings count by severity (critical / high / medium / low).
- The top 3 highest-severity findings with their file:line citations.

Do NOT modify `STATE.md` from this command.
