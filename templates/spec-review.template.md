# Spec review: <slug>

## Frame

> Imagine it is 3am, the on-call engineer is paged because this system is on fire in production.
> What in the spec, as written, made the failure possible? What is missing, ambiguous, or
> contradictory that will hurt the engineer right now?
>
> The reviewer's job is to find as many such failure modes as possible BEFORE we approve the spec.

## Objections

> Minimum 7 slots. Each objection has: severity, area, scenario, fix, FR/NFR ref.
> Severity: **block** (spec cannot proceed) / **major** (must address before ADRs) / **minor** (note for later).
> Area: **NFR** / **scope** / **edge** / **contradiction** / **missing**.

### Objection 1

- **Severity**: <block | major | minor>
- **Area**: <NFR | scope | edge | contradiction | missing>
- **Scenario**: <concrete 3am failure mode this objection describes>
- **What to fix**: <change to spec that closes this hole>
- **Refs**: FR-<N> / NFR-<KIND>-<N> / "missing — no ID yet"

### Objection 2

- **Severity**: ...
- **Area**: ...
- **Scenario**: ...
- **What to fix**: ...
- **Refs**: ...

### Objection 3

- ...

### Objection 4

- ...

### Objection 5

- ...

### Objection 6

- ...

### Objection 7

- ...

> Add more slots as needed. 7 is the floor, not the ceiling.

## Self-rating pass

> For each objection above, the reviewer rates how deeply it was thought through.
> Goal: catch the reviewer's own sycophancy / shallow padding.

| # | Depth (deep / medium / shallow) | Reason for the rating |
|---|---------------------------------|-----------------------|
| 1 | <deep \| medium \| shallow>     | <why this rating>     |
| 2 | <...>                           | <...>                 |
| 3 | <...>                           | <...>                 |
| 4 | <...>                           | <...>                 |
| 5 | <...>                           | <...>                 |
| 6 | <...>                           | <...>                 |
| 7 | <...>                           | <...>                 |

## Verdict

> Allowed only if **at least 5** objections are rated deep or medium AND survive the self-rating pass.
> If fewer than 5 deep+medium objections survive, the reviewer must do another pass — verdict is invalid.

- **Verdict**: <block | needs-changes | approve-with-notes>
- **Justification**: <one paragraph; reference objection numbers>
