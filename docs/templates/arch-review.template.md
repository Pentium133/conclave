# Architecture review: <slug>

## Per-ADR review

### ADR-001: <title>

- **Verdict**: <accept | challenge | reject>
- **Arguments**:
  - <argument #1: technical reason for the verdict, referencing FR/NFR-IDs and trade-off axes from the ADR>
  - <argument #2>
  - <argument #3>

### ADR-002: <title>

- **Verdict**: ...
- **Arguments**:
  - ...

### ADR-NNN: <title>

- ...

## Disagree-flag

> MANDATORY. This section MUST NOT be empty. The reviewer must take ONE of the two stances below.
> A blank or evasive value here invalidates the entire review.

- **Stance**: <"I disagree with X" | "none — considered objections [list] and rejected because [reasons]">
- **Detail**:
  - If stance = "I disagree with X": describe the disagreement, what evidence would change your mind, and which ADR/decision it affects.
  - If stance = "none": list the candidate objections you considered, and explain why each was rejected (with technical reasoning, not "looks fine").

## Production failure scenarios

> Concrete scenarios where this architecture, as described, fails in production.
> Each scenario must be plausible (not "what if a meteor"), tied to specific ADRs.

- **Scenario 1**: <e.g. "DeepSeek returns 429 for 30s burst → ADR-002 retry policy amplifies load → cascade failure">
- **Scenario 2**: <...>
- **Scenario 3**: <...>

## Cross-cutting issues

> Issues that span multiple ADRs or aren't owned by any single ADR.

- <issue #1: e.g. "no ADR addresses observability of inter-component calls; ADR-003 and ADR-005 both assume traces but neither owns them">
- <issue #2>

## Final verdict

- **Verdict**: <block | iterate | approve>
- **Required follow-ups before next stage**:
  - <follow-up #1>
  - <follow-up #2>
