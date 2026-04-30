---
description: Produce ADRs from the spec and applied verdicts. Invokes the architect subagent.
allowed-tools: Bash, Read, Task
---

# /architect

Wrapper-only: validate state, hand off to the `architect` subagent.

## Resolve active project

1. Read `process/CURRENT`. If missing/empty, print «No active project. Run `/start <slug>` first.» and stop.
2. Verify `process/<slug>/STATE.md` exists; if not, print remediation and stop.

## Stage validation

Read the YAML frontmatter `stage:` field of `process/<slug>/STATE.md`. Allowed stages for `/architect`:

- `verdicts-applied` — normal path: the developer applied skeptic verdicts to `spec.md`.
- `spec-reviewed` — allowed only when the developer decided the verdicts were no-action-needed. Verify this by grepping `process/<slug>/STATE.md` for a log line containing the substring `no-action-needed` or `verdicts considered no-action-needed`. If the substring is missing, refuse with:

  «Cannot run `/architect` from `spec-reviewed` without a log line confirming verdicts were considered. Either apply verdicts and set `stage: verdicts-applied`, or append the no-action-needed log line manually, then re-run.»

For any other stage, refuse:

«Cannot run `/architect`: current stage is `<X>`, expected `verdicts-applied` (or `spec-reviewed` with a no-action-needed log line). Run `/status` to see what to do next.»

## Hand off to subagent

Invoke the `architect` subagent via the Task tool (`subagent_type: architect`). Pass it a prompt with these absolute paths:

- `process/<slug>/spec.md` — source of FR-N / NFR-KIND-N IDs (read-only).
- `process/<slug>/spec-review.md` — applied verdicts (read-only). Every `block` and `major` objection must be addressed.
- `docs/templates/adr.template.md` — exact ADR structure.
- `process/<slug>/STATE.md` — the architect owns updating it.
- Target directory: `process/<slug>/adr/` — write `NNN-<topic>.md` files here.

Tell the subagent: «You own writing ADRs into `process/<slug>/adr/` and updating `STATE.md` (set `stage: arch-proposed`, tick checkbox, replace ADR placeholder line with one entry per real ADR, append log line). The slash command does not touch these files.»

## After return

List the ADR filenames the architect produced (use `ls process/<slug>/adr/`). Print to the developer:

«Architect produced N ADRs in `process/<slug>/adr/`. Run `/review-arch` to get an independent review of the architecture.»

Do NOT modify `STATE.md` from this command.
