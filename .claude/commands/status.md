---
description: Show the active project's current stage, checklist, artifacts and pending human action.
allowed-tools: Bash, Read
---

# /status

You are reporting on the current pipeline state. Read-only — do not modify any file.

## Actions

1. Check `process/CURRENT`. If the file does not exist or is empty, print:

   «No active project. Run `/start <slug>` to begin.»

   and stop.

2. Read the slug from `process/CURRENT` (strip whitespace).

3. Verify `process/<slug>/STATE.md` exists. If not, print:

   «`process/CURRENT` points to `<slug>` but `process/<slug>/STATE.md` is missing. Either fix `process/CURRENT` or re-run `/start <slug>`.»

   and stop.

4. Read `process/<slug>/STATE.md`. Parse:
   - YAML frontmatter `slug`, `stage`, `created`, `last_updated`.
   - The `## Current stage` checklist (which boxes are ticked).
   - The `## Artifacts` list with statuses.
   - The `## Pending human action` body verbatim.

5. Render to the user in this exact shape:

   ```
   Project: <slug>
   Stage:   <stage>     (created <created>, last updated <last_updated>)

   Checklist:
     [x] intake — <date>
     [x] interview — <date>
     [ ] spec-approved — ...
     ...

   Artifacts:
     spec.md         — <status>
     spec-review.md  — <status>
     adr/...         — <status>
     arch-review.md  — <status>
     post-review.md  — <status>

   Pending human action:
     <verbatim body>
   ```

## Forbidden

- Do not edit `STATE.md` or any other file. This command is purely diagnostic.
- Do not invoke subagents.
