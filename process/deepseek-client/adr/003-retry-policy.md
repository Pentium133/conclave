# ADR-003: Implement retry policy as a stateless orchestrator with two failure classes

## Status

proposed

## Context

FR-5 splits retry-eligible failures into Class A (transport, before any response
bytes) and Class B (upstream HTTP 502 / 503). FR-6 caps retries at 1, with a
fixed 500 ms ±20 % uniform jitter for Class A, and `min(Retry-After, remaining
wall-time − one-attempt budget)` for Class B. The spec also requires that
`Retry-After` parsing handle both `delta-seconds` and HTTP-date forms (RFC 7231),
that absent / malformed values be treated as 0 (immediate retry, subject to wall
time), and that retries be **abandoned** when `Retry-After` exceeds remaining
wall-time. The orchestrator must also coexist with NFR-LAT-1's wall-time guard
(ADR-002) so that a retry never starts if it cannot finish before 30 s.

This ADR **resolves spec-review objection 5** (the spec used to forbid retry on
all 5xx; the amended spec carves out 502 / 503 — the orchestrator must implement
that carve-out) and **contributes to objection 7** (Retry-After value plumbing on
the upstream-429-forwarded path stays verbatim — no retry, just forward).

- Drives: FR-5, FR-6, FR-7 (insofar as it specifies "no retry on local 429"),
  NFR-LAT-1, NFR-LAT-2.
- Resolves: spec-review objection 5 (Class B carve-out for 502 / 503).
- Contributes to: spec-review objection 7 (upstream Retry-After forwarded
  verbatim, never used by the local orchestrator on the upstream-429 path).
- Contributes to: spec-review objection 1 (the orchestrator is the caller of
  ADR-002's AbortController; one-attempt budget interacts with wall-time guard).

## Alternatives

### Alternative A: Inline orchestrator — a single async function `runWithRetry(req, ctx)` that owns the budget, classification, and backoff

- **Cost**: Zero new dependencies. ~120 LOC.
- **Complexity**: One function, easy to reason about; the entire retry state lives
  in local variables (`attempt`, `requestStart`, `remainingWallTime`).
- **Correctness**: The classification table (Class A → retry; Class B → retry; mid-
  body / 4xx / 500 / 504 → no-retry) is a switch on the typed error from ADR-002 plus
  a switch on `response.statusCode`. Every branch is explicit; FR-5 / FR-6 read off
  the source nearly line-for-line.
- **Operability**: Test surface is small; the FR-5 table is one parameterised
  test fixture.
- **Verdict**: chosen — the spec's retry contract is small enough that a generic
  retry library would add dependencies and indirection without buying us anything we
  don't already have.

### Alternative B: A generic retry library (e.g., `cockatiel`, `async-retry`, `p-retry`)

- **Cost**: One more dependency to track for security updates and Node version
  compat.
- **Complexity**: Non-trivial. None of these libraries natively understand "retry on
  Class A errors *or* HTTP 502 / 503 *but only when no response bytes were consumed*";
  we would still have to write a custom predicate, plus a custom backoff calculator
  for the `Retry-After`-aware Class B branch.
- **Correctness**: The library handles the general case; the spec's Class A vs B
  split with response-byte-cutoff and `min(Retry-After, remaining)` is unusual enough
  that we end up writing the same logic inside the library's hooks anyway. The risk
  is a subtle FR-5-cutoff bug (e.g., the library re-runs the upstream call after
  bodyTimeout fired mid-stream).
- **Operability**: Behaviour during an upgrade is not in our hands.
- **Verdict**: rejected — the library's value is amortised over many retry sites; we
  have one.

### Alternative C: No retries at all (forward every failure verbatim)

- **Cost**: Zero. The simplest possible code.
- **Complexity**: Trivial.
- **Correctness**: Violates FR-5 / FR-6. During DeepSeek transport blips and edge LB
  outages (objection 5), the proxy would expose the caller to a much higher error
  rate than the spec's accepted budget.
- **Operability**: Easy to debug, but the operational cost is paid by every caller
  on every blip.
- **Verdict**: rejected — explicitly contradicts the amended spec.

## Decision

We implement **Alternative A**: an inline async function `runWithRetry(rawBody,
ctx)` invoked once per inbound request from the Fastify handler.

Pseudo-spec:

```
const requestStart = Date.now();
const WALL_TIME_MS = 30_000;
const ATTEMPT_BUDGET_MS = 12_000;          // NFR-LAT-2 per-attempt total
let attempt = 0;

while (true) {
  const remaining = WALL_TIME_MS - (Date.now() - requestStart);
  if (remaining <= 0) return gatewayTimeout();   // NFR-LAT-1
  // ADR-002 supplies signal + per-attempt timeouts; orchestrator just runs it.
  const result = await callUpstream(rawBody, { signal, attemptBudget: Math.min(ATTEMPT_BUDGET_MS, remaining) });

  if (result.kind === 'http' && retryableStatus(result.status) && attempt === 0) {
    // FR-5 Class B: 502 or 503.
    const retryAfter = parseRetryAfter(result.headers['retry-after']);   // delta-sec OR HTTP-date OR null
    const cap = remaining - ATTEMPT_BUDGET_MS;                           // FR-6: leave one attempt's worth.
    if (cap <= 0) return forwardUpstream(result);                        // not enough budget for the retry.
    const delay = retryAfter == null ? 0 : Math.min(retryAfter, cap);    // 0 for absent / malformed.
    await sleep(delay);
    attempt++;
    continue;
  }
  if (result.kind === 'classA' && attempt === 0) {
    // FR-5 Class A: connect / DNS / pre-headers timeout / TLS / RST-before-headers.
    const jitterMs = 400 + Math.random() * 200;                          // FR-6: 500ms ± 20%
    if (jitterMs > remaining - ATTEMPT_BUDGET_MS) return transportError(); // would blow wall-time.
    await sleep(jitterMs);
    attempt++;
    continue;
  }
  // Anything else: forward as-is OR map to transport_error / gateway_timeout.
  return result;
}
```

Key invariants encoded by this function:

- **One retry max** (FR-6): `attempt === 0` guards both retry branches.
- **Class B Retry-After** (FR-5 / FR-6): parser supports `delta-seconds` AND
  HTTP-date (RFC 7231); `null` / malformed = `0` = immediate retry, subject to
  remaining wall-time.
- **Wall-time short-circuit** (NFR-LAT-1): if remaining < per-attempt budget, no
  retry — forward the original 502 / 503 to the caller.
- **No retry on local 429** (FR-7): the local rate-limiter (ADR-004) returns
  before this orchestrator is invoked, so this path never sees its own 429.
- **No retry on upstream 429** (FR-7): `retryableStatus` only matches `502 || 503`.
  The upstream `Retry-After` on a 429 response is forwarded verbatim by the
  Fastify response stage, never inspected here.
- **No retry mid-body** (FR-5 cutoff): ADR-002 surfaces mid-body transport errors
  as a distinct kind (`transportMidBody`), which neither `retryableStatus` nor
  `result.kind === 'classA'` matches, so the orchestrator forwards them as
  `transport_error` (502 to caller) without retry.

This **resolves spec-review objection 5** by encoding the 502 / 503 carve-out as a
specific branch with documented Retry-After semantics, and **contributes to
objection 7** by leaving the upstream-429 Retry-After untouched (it is part of the
verbatim response forwarded by ADR-001's response stage; the orchestrator does not
read or modify it).

## Consequences

### Positive

- One function, ~120 LOC, with the FR-5 / FR-6 contract readable inline. The
  NFR-LAT-1 wall-time guard short-circuits naturally at the `while` head.
- Class A vs Class B branches are distinct in code, so we can extend either
  independently (e.g., adding 504 to Class B in a future iteration is a one-line
  change).
- Retry-After parsing is centralised; the `delta-seconds` vs HTTP-date branches
  share the same `min(value, cap)` reduction.

### Negative

- 502 / 503 carve-out **does** expose us to the double-billing risk the spec's
  original "no 5xx retry" rule was guarding against, *if* DeepSeek's edge LB
  returns a 502 *after* the model has already processed the prompt (e.g., a TCP
  reset between the LB and the model that the LB serialises as 502 to us). The
  spec accepts this risk (rationale: 502 / 503 are edge-shaped, the model
  probably did not run); we surface it explicitly here so the arch-reviewer can
  challenge it.
- The `Math.random()` jitter is non-deterministic — reproducing a precise
  retry-time-induced bug requires log timestamps. Acceptable: NFR-OBS-1's
  `latency_ms` and `upstream_latency_ms` give the operator the offset.
- `Retry-After: 0` (immediate retry) on every blip means a tight retry loop
  capped only by wall-time. With one retry per request and 12 s per attempt,
  the worst case is still bounded — but a malformed `Retry-After: -5` on every
  request could cause the orchestrator to retry as fast as it can in a tight
  burst from many concurrent inbound requests. NFR-CAP-1 (ADR-004) caps the
  outbound rate at 5 RPS so this cannot become an outbound storm; the bound
  holds.
- The orchestrator's behaviour with `Retry-After` larger than the wall-time
  remaining is "no retry, forward the 502/503". The caller sees an `upstream_5xx`
  outcome with no retry having been attempted. This is the spec, but on-call
  metrics will show an 'apparent' retry-budget burn when in fact the budget was
  never used.

## Open questions

- Should the FR-5 classification table be a `Map<UND_ERR_CODE, FailureClass>`
  exported as data (so tests can iterate it) or inlined as a `switch`? We will
  prefer the data form to make ADR-002's coupling testable.
- The spec's "Retry-After absent / malformed → 0" decision is the safest for
  liveness but the most aggressive on the upstream. The arch-reviewer may push
  for a small fallback (e.g., 200 ms) to avoid exactly-back-to-back attempts on
  a flapping edge LB; we keep 0 for now, in line with the spec literal.
