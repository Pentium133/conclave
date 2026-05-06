---
description: Implement a narrow chunk of the design as code+tests. Invokes the implementer subagent.
argument-hint: <scope-description> [--lang <python|ts|...>]
allowed-tools: Bash, Read, Task
---

# /implement

Wrapper-only: validate state, hand off to the `implementer` subagent.

## Argument

`$ARGUMENTS` is a free-form scope description (one chunk to build, e.g. `retry-handler` or `deepseek-client class`), optionally followed by `--lang <name>` for the target language. If `$ARGUMENTS` is empty, refuse:

«`/implement` requires a scope description. Usage: `/implement <scope-description> [--lang <python|ts|...>]`. Example: `/implement retry-handler` or `/implement deepseek-client class --lang python`.»

and stop. Otherwise pass `$ARGUMENTS` verbatim to the subagent.

## Resolve active project

1. Read `process/CURRENT`. If missing/empty, print «No active project. Run `/start <slug>` first.» and stop.
2. Verify `process/<slug>/STATE.md` exists; if not, print remediation and stop.

## Stage validation

Read the YAML frontmatter `stage:` field of `process/<slug>/STATE.md`. Allowed stages: `arch-reviewed`, `implemented`.

The `implemented` stage is allowed so the developer can add a second focused chunk to the same project (one `/implement` per chunk).

If the stage is anything else, refuse:

«Cannot run `/implement`: current stage is `<X>`, expected `arch-reviewed` or `implemented`. Run `/status` to see what to do next. Note: `/implement` is optional — the design pipeline ends at `arch-reviewed`. Use `/implement` only if you want to demonstrate post-review on real code.»

and stop.

## Hand off to subagent

Invoke the `implementer` subagent via the Task tool (`subagent_type: implementer`). Pass it a prompt with these inputs:

- `process/<slug>/spec.md` — FR-N / NFR-KIND-N IDs to satisfy (read-only).
- `process/<slug>/adr/*.md` — architectural decisions to follow (pass the glob; the subagent will expand it via Glob).
- `process/<slug>/arch-review.md` — accepted with caveats and required follow-ups (read-only context).
- `process/<slug>/STATE.md` — the subagent owns updating it.
- Scope from `$ARGUMENTS` — exact scope description and optional `--lang`.

Tell the subagent: «You own writing code under `src/`, tests under `tests/`, optionally creating/updating `requirements.txt`, and updating `STATE.md` (set `stage: implemented`, tick checkbox, append Artifacts line, append log line including ADR-IDs cited and test count, set Pending human action to `/audit-code <paths>`). Do NOT modify `spec.md`, ADRs, or `arch-review.md`. Stay strictly inside the named scope.»

## After return

Summarise to the developer:

- Files created (under `src/` and `tests/`).
- Test command run and final test summary line (e.g. `5 passed in 0.42s`).
- ADR-IDs cited in code comments.
- Next step: «Run `/audit-code <paths>` to verify the implementation against spec and ADRs.»

Do NOT modify `STATE.md` from this command.
