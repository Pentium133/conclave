---
description: Start a new pipeline project. Creates process/<slug>/ skeleton and sets stage=intake.
argument-hint: <project-slug>
allowed-tools: Bash, Read, Edit, Write
---

# /start

You are bootstrapping a new project in the Claude Code agent pipeline.

## Argument

`$ARGUMENTS` is the project slug. Validate it strictly:

- Lowercase only.
- Allowed characters: `a-z`, `0-9`, `-`.
- Must not start or end with `-`, must not contain `--`.
- Must be non-empty.

If invalid, refuse with: «Invalid slug `<value>`. Use lowercase-kebab-case (e.g. `deepseek-client`).» and stop.

## Preconditions

- If `process/<slug>/` already exists, refuse: «Project `<slug>` already exists at `process/<slug>/`. Pick a different slug or continue with `/status`.» and stop.

## Actions

1. Create directories: `process/<slug>/` and `process/<slug>/adr/`.
2. Copy `docs/templates/STATE.template.md` to `process/<slug>/STATE.md`.
3. Edit `process/<slug>/STATE.md`:
   - Replace `<kebab-case-slug>` with the slug.
   - Replace the `stage:` line with `stage: intake`.
   - Replace `created: <YYYY-MM-DD>` with today's date (use `date +%Y-%m-%d`).
   - Replace `last_updated: <YYYY-MM-DD>` with today's date.
   - Replace `# STATE: <slug>` heading with `# STATE: <slug>`.
   - In the stage checklist, tick `intake`: change `- [ ] intake — <YYYY-MM-DD>` to `- [x] intake — <today>`.
   - Set `## Pending human action` body to: «Run `/interview` to start requirements gathering.»
   - Append a log line under `## Log`: `- <today HH:MM> — project bootstrapped, stage=intake` (use `date '+%Y-%m-%d %H:%M'`).
4. Write the slug into `process/CURRENT` (single line).

## Output

Echo to the user, verbatim:

«Started `<slug>`. Run `/interview` to begin requirements gathering.»

Do not invoke any subagent. Do not change anything else.
