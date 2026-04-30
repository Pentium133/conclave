---
description: Independent architecture review. Invokes the arch-reviewer subagent on the spec and ADRs.
allowed-tools: Bash, Read, Task
---

# /review-arch

Wrapper-only: validate state, hand off to the `arch-reviewer` subagent.

## Resolve active project

1. Read `process/CURRENT`. If missing/empty, print «No active project. Run `/start <slug>` first.» and stop.
2. Verify `process/<slug>/STATE.md` exists; if not, print remediation and stop.

## Stage validation

Read the YAML frontmatter `stage:` field of `process/<slug>/STATE.md`. Allowed stage: `arch-proposed`.

If the stage is anything else, refuse:

«Cannot run `/review-arch`: current stage is `<X>`, expected `arch-proposed`. Run `/status` to see what to do next.»

and stop.

## Critical isolation rule

The `arch-reviewer` subagent MUST form an independent view of the architecture. The developer's whole point in running two reviewers (spec-skeptic and arch-reviewer) is to get two unaligned perspectives. Therefore:

> The prompt you pass to the subagent MUST NOT reference, mention, or include the path to the prior spec review file. Do not list it among the inputs. Do not "for context" attach it. The subagent's own prompt forbids reading it; do not even surface its existence.

Concretely, the inputs you pass to the subagent are EXACTLY these four, no others:

- `process/<slug>/spec.md` — requirements (read-only).
- The list of ADR file paths under `process/<slug>/adr/` — gather with `ls process/<slug>/adr/*.md` and pass the resulting paths.
- `docs/templates/arch-review.template.md` — exact output structure.
- `process/<slug>/STATE.md` — the subagent owns updating it.

## Hand off to subagent

Invoke `arch-reviewer` via the Task tool (`subagent_type: arch-reviewer`). Pass the four inputs above. Tell the subagent: «You own writing `process/<slug>/arch-review.md` and updating `STATE.md` (set `stage: arch-reviewed`, tick checkbox, update Artifacts, append log line). The slash command does not touch these files.»

## After return

Read `process/<slug>/arch-review.md` and summarise to the developer:

- Final verdict (`block` / `iterate` / `approve`).
- Per-ADR verdicts and the disagree-flag content from each per-ADR section (verbatim).
- Required follow-ups list.

Do NOT modify `STATE.md` from this command.
