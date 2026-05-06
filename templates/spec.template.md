# Spec: <slug>

## Goal

<one-sentence statement of what we are building and why; the developer should agree this is the problem>

## Functional requirements

- **FR-1**: <one-line functional requirement; what the system must do>
- **FR-2**: <one-line functional requirement>
- **FR-3**: <...>

> Each FR has a stable ID (FR-N). Reviews and ADRs reference these IDs.

## Non-functional requirements

### Latency

- **NFR-LAT-1**: <e.g. "p99 end-to-end latency under load X is < Y ms">
- <or note: "no explicit requirement; assume best-effort" if developer says so>

### Throughput

- **NFR-THR-1**: <e.g. "sustains N requests/sec at peak">

### Availability / SLA

- **NFR-AVL-1**: <e.g. "99.9% monthly availability; tolerated downtime budget = 43 min/mo">

### Durability

- **NFR-DUR-1**: <e.g. "no data loss on single-node failure; RPO = 0 / RPO = 5 min / RPO = N/A (stateless)">

### Security

- **NFR-SEC-1**: <e.g. "secrets never logged; auth via X; threat model: Y">

### Observability

- **NFR-OBS-1**: <e.g. "structured logs at INFO/WARN/ERROR; metrics: latency histogram, error rate, saturation; traces with correlation IDs">

### Capacity

- **NFR-CAP-1**: <e.g. "expected load = N RPS, peak = M RPS, growth horizon = 12 months">

### Dependencies

- **NFR-DEP-1**: <upstream services / libs / SDKs the design assumes; e.g. "DeepSeek HTTP API (vendor-controlled, may rate-limit)">

### Deployment

- **NFR-DEP-2**: <where it runs; e.g. "single container, ECS Fargate; deploy via blue-green; config via env vars">

## Out of scope

- <thing #1 we explicitly do NOT build, with one-line reason>
- <thing #2>

## Open assumptions

> Interviewer-agent records assumptions here in the form `[ASSUMED: <statement> — <reason / source>]`.
> Each assumption MUST be explicitly confirmed or denied by the developer before §Approval.

- [ASSUMED: <example assumption — e.g. "DeepSeek API base URL is api.deepseek.com">]

## Approval

> Developer writes `approve` and the date below. Without this, no downstream stage may proceed.

- Status: <pending | approved>
- Approved by: <developer-name>
- Date: <YYYY-MM-DD>
