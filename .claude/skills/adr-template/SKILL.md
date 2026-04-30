---
name: adr-template
description: Use when writing or updating an ADR file in `process/<slug>/adr/` — defines the canonical ADR structure and trade-off discipline.
---

# ADR template skill

Canonical template: `docs/templates/adr.template.md`. Copy it for every new ADR.

## Filename convention

`process/<slug>/adr/NNN-<kebab-topic>.md`

- `NNN` is sequential from `001`, zero-padded to 3 digits. Never reuse a number.
- `<kebab-topic>` is descriptive, not generic. Examples:
  - GOOD: `001-retry-policy.md`, `002-streaming-buffer-strategy.md`, `003-deepseek-timeout.md`
  - BAD: `001-design.md`, `002-architecture.md`, `003-decisions.md`

## Required sections

Every ADR MUST contain:

1. `## Status` — one of `proposed` / `accepted` / `superseded`.
2. `## Context` — MUST list the `FR-N` and `NFR-KIND-N` IDs from `spec.md` that drive this decision. If you can't cite any, this isn't an ADR.
3. `## Alternatives` — at least 2 alternatives. Each is rated on FOUR axes:
   - cost
   - complexity
   - correctness
   - operability
   None of those four axes may be left empty for any alternative.
4. `## Decision` — chosen variant + rationale that explicitly references the FR/NFR-IDs from Context.
5. `## Consequences` — with mandatory `### Negative` subsection. The `### Negative` subsection MUST be non-empty.
6. `## Open questions`.

## Rules for the architect subagent

- **One ADR per decision point.** Don't bundle "retry policy + buffer strategy + timeout" into one file — split them.
- **"Obvious choice" ADRs are still allowed**, but the Alternatives list MUST contain at least one explicitly inferior alternative so the trade-off is visible. An ADR with one alternative is rejected.
- **Cite specific IDs in `## Decision`.** If the decision rationale doesn't reference any `FR-N` or `NFR-KIND-N`, the decision doesn't belong in an ADR — push it back to the spec or to code comments.
- **`### Negative` is mandatory and non-empty.** Phrases like "no significant negatives", "none", "n/a" are NOT allowed. Every architectural choice has a cost — find it.
- **Spec-review accounting.** For every objection from `spec-review.md` marked `block` or `major`, there must be visible accounting somewhere across the ADRs (in `## Context` or `## Consequences`), citing the objection number (e.g. "addresses spec-review #4"). If an ADR set leaves a `block`/`major` objection un-cited, it's incomplete.
