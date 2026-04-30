# Architecture review: <slug>

## Per-ADR review

> Repeat this subsection for every ADR in `process/<slug>/adr/`.
> Disagree-flag is REQUIRED at the end of every per-ADR subsection — it is the
> per-ADR antisycophancy mechanism. An empty or evasive disagree-flag invalidates
> the entire review.

### ADR-001: <title>

- **Verdict**: <accept | challenge | reject>
- **Arguments** (≥3 concrete, technical, citing FR/NFR-IDs and trade-off axes):
  - <argument #1>
  - <argument #2>
  - <argument #3>
- **3am production failure scenarios** (≥2 specific scenarios — name trigger, chain, what on-call sees):
  - <scenario #1>
  - <scenario #2>
- **Operational problems** (alerts, runbooks, manual steps, capacity footguns):
  - <problem #1>
- **Disagree-flag (MANDATORY, MUST NOT be empty — pick exactly one form)**:
  - **Form 1**: `I disagree with: <specific decision in this ADR and the technical reason why>`, OR
  - **Form 2**: `I considered the following objections [≥2 candidate objections, each with reasoning] and rejected them because [per-objection rejection reasons]`.

### ADR-002: <title>

- **Verdict**: ...
- **Arguments**:
  - ...
- **3am production failure scenarios**:
  - ...
- **Operational problems**:
  - ...
- **Disagree-flag**:
  - ...

### ADR-NNN: <title>

- ...

## Cross-cutting issues

> Issues that span multiple ADRs or aren't owned by any single ADR.

- <issue #1: e.g. "no ADR addresses observability of inter-component calls; ADR-003 and ADR-005 both assume traces but neither owns them">
- <issue #2>

## Final verdict

- **Verdict**: <block | iterate | approve>
- **Required follow-ups before next stage**:
  - <follow-up #1>
  - <follow-up #2>
