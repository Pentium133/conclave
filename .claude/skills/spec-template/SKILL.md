---
name: spec-template
description: Use when filling or updating `process/<slug>/spec.md` — provides the canonical spec format and required sections.
---

# Spec template skill

Canonical template: `docs/templates/spec.template.md`. Always start by copying it.

## Required sections checklist

Every `spec.md` MUST contain these sections — none may be omitted:

1. `## Goal`
2. `## Functional requirements` — numbered `FR-N`
3. `## NFR` — with all 9 subsections below
4. `## Out of scope`
5. `## Open assumptions`
6. `## Approval`

### NFR subsections (all 9 required, none may be missing)

- `### Latency`
- `### Throughput`
- `### Availability/SLA`
- `### Durability`
- `### Security`
- `### Observability`
- `### Capacity`
- `### Dependencies`
- `### Deployment`

## ID conventions (interviewer subagent)

- **FR-IDs** are sequential starting at `FR-1`. Never reuse a number, never skip.
- **NFR-IDs** are namespaced by category, each category counts independently from 1:
  - Latency: `NFR-LAT-1`, `NFR-LAT-2`, ...
  - Throughput: `NFR-THR-1`, ...
  - Availability/SLA: `NFR-AVL-1`, ...
  - Durability: `NFR-DUR-1`, ...
  - Security: `NFR-SEC-1`, ...
  - Observability: `NFR-OBS-1`, ...
  - Capacity: `NFR-CAP-1`, ...
  - Dependencies: `NFR-DEP-1`, ...
  - Deployment: `NFR-DPL-1`, ...

## Completeness rules

- An NFR subsection is "complete" only when it contains EITHER:
  - at least one concrete `NFR-KIND-N` entry, OR
  - an `[ASSUMED: <value> — reason: ...]` line.
- A subsection that is present but empty does NOT count as complete. Either get a value from the developer or add an `[ASSUMED]` line.
- Every `[ASSUMED: ...]` line in the NFR sections MUST also appear under `## Open assumptions` in summary form (one bullet per assumption, with a back-reference to the NFR-ID).

## Approval

The `## Approval` section is set ONLY when the developer types literally `approve` and a date. The interviewer subagent must never fill this in itself, and must never accept paraphrases (e.g. "lgtm", "ok", "approved by me") — only the exact word `approve` plus a date.
