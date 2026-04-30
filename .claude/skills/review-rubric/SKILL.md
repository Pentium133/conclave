---
name: review-rubric
description: Use when generating `process/<slug>/spec-review.md` or `process/<slug>/arch-review.md` — defines depth rubric, two-pass discipline, and disagree-flag conventions.
---

# Review rubric skill

Used by both `spec-skeptic` (spec review) and `arch-reviewer` (ADR review).

## Depth rubric

Every objection is rated on this 3-tier scale:

### deep
Identifies a specific 3am production failure mode with a concrete trigger, a chain of events, and an observable symptom.

Example: «If DeepSeek returns HTTP 429 with a `Retry-After` header longer than the spec's 30s timeout, the client will discard the hint and immediately retry, multiplying load — on-call sees a sustained 100% upstream-429-rate metric.»

### medium
Identifies a real concern with a plausible scenario but lacks specificity on either the trigger or the observable signal.

Example: «No clear policy for partial streaming responses; could leave consumers with truncated payloads.»

### shallow
Generic advice without scenario, signal, or actionable fix. NOT acceptable. Discard.

Anti-examples: «Consider observability» / «Think about scale» / «What about retries?» / «Make sure it's secure».

## Two-pass discipline (spec-skeptic)

- **Pass 1.** Generate at least 7 numbered objections. Each objection has: severity (`block`/`major`/`minor`), area, scenario, what-to-fix, refs (to `FR-N`/`NFR-KIND-N`).
- **Pass 2.** Re-read every Pass 1 objection. Rate each as `deep` / `medium` / `shallow` with a one-line reason. Discard everything `shallow`.
- **Verdict gate.** A verdict (block/approve/etc.) is only allowed when at least 5 deep+medium objections survive Pass 2.
- **Gate failure.** If the gate is not met, write literally «Insufficient depth — Pass 1 must be redone» and stop. Do NOT lower the bar by promoting shallow items.

## Disagree-flag conventions (arch-reviewer)

A disagree-flag is MANDATORY at the end of EVERY per-ADR section (not at the top level of the review — per ADR).

Two acceptable forms — one MUST be used:

- **Form 1:** «I disagree with: <specific decision in this ADR and the technical reason why>»
- **Form 2:** «I considered the following objections [list ≥2 candidate objections, each with technical reasoning] and rejected them because [per-objection rejection reasons]»

Empty, evasive, or hand-wavy values invalidate the entire review. Examples that INVALIDATE:
- «No disagreements.»
- «Looks fine.»
- «Nothing to add.»

The reviewer must commit to one of the two forms above for every ADR.

## Forbidden phrases (both reviewers)

These phrases are banned from `spec-review.md` and `arch-review.md`:

- «Looks good overall»
- «Good catch by the author»
- «Seems fine»
- «Consider X» without a specific scenario, signal, or threshold
- Any praise of the artifact's author (the review is about the artifact, not the writer)
