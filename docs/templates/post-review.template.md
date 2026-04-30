# Post-implementation review: <slug>

> Compares the shipped code against `spec.md` and `adr/`. Cites file:line for every claim.

## Per-FR check

| FR-ID | Status (met / not met / not testable) | Evidence (file:line) | Notes |
|-------|---------------------------------------|----------------------|-------|
| FR-1  | <met \| not met \| not testable>      | `path/to/file.py:42` | <one-line note> |
| FR-2  | <...>                                 | `<file>:<line>`      | <...> |
| FR-N  | <...>                                 | <...>                | <...> |

## Per-NFR check

| NFR-ID | Status (met / not met / not testable) | Evidence (file:line / metric / log) | Notes |
|--------|---------------------------------------|--------------------------------------|-------|
| NFR-LAT-1 | <met \| not met \| not testable>   | `<file>:<line>` or "load test report `<path>`" | <...> |
| NFR-OBS-1 | <...>                              | <...> | <...> |
| NFR-SEC-1 | <...>                              | <...> | <...> |
| ...       | <...>                              | <...> | <...> |

## Per-ADR check

| ADR-ID | Status (implemented / deviated / not implemented) | Evidence (file:line) | Deviation reason (if any) |
|--------|---------------------------------------------------|----------------------|----------------------------|
| ADR-001 | <implemented \| deviated \| not implemented>     | `<file>:<line>`      | <only if deviated>         |
| ADR-002 | <...>                                            | <...>                | <...>                      |
| ADR-NNN | <...>                                            | <...>                | <...>                      |

## Findings

> Bugs, NFR violations, missing observability, undocumented deviations.
> Severity: **critical** (ship-blocker) / **high** (fix this sprint) / **medium** / **low**.

### Finding 1

- **Severity**: <critical | high | medium | low>
- **Category**: <bug | NFR violation | missing observability | undocumented deviation | security>
- **Evidence**: `<file>:<line>` — <code snippet or log excerpt>
- **Impact**: <what breaks / what we cannot see in production>
- **Suggested fix**: <one-line action>

### Finding 2

- ...

### Finding N

- ...

## Verdict

- **Verdict**: <ship | fix-required | reject>
- **Justification**: <one paragraph tying verdict to findings; cite Finding numbers and FR/NFR/ADR IDs>
