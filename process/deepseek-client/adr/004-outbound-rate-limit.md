# ADR-004: Hand-rolled in-process token bucket for outbound rate limiting

## Status

proposed

## Context

NFR-CAP-1 mandates a process-wide outbound token bucket with steady-state 5 RPS
and burst capacity 5. FR-7 mandates **immediate rejection** with HTTP 429 when
the bucket is empty — no internal queue, no internal delay — plus two response
headers: `Retry-After` (whole seconds, rounded up, minimum 1) and a
millisecond-precision `X-RateLimit-Reset-Ms`. Both numbers must be derived from
the same monotonic clock used to refill the bucket.

Single-process Node executes JavaScript on a single thread, so the token bucket
needs no concurrency primitives — `Date.now()` reads and a single mutable
`tokens` field are atomic with respect to other JS code paths. The challenge is
not concurrency; it is making sure the rejection path is genuinely immediate
(no `await` between bucket-check and 429 response) and that the two `Retry-After`
header values are computed once and stay consistent.

This ADR **contributes to spec-review objection 7** (the local-429 vs
upstream-429 Retry-After plumbing) by pinning down which value the local
overflow path emits, in millisecond precision.

- Drives: NFR-CAP-1, FR-7, NFR-OBS-1 (`outcome=rate_limited` on local overflow).
- Contributes to: spec-review objection 7 (Retry-After + X-RateLimit-Reset-Ms
  semantics on local overflow).

## Alternatives

### Alternative A: Hand-rolled refill-on-read token bucket using `process.hrtime.bigint()` for the monotonic clock

- **Cost**: ~30 LOC, no dependency.
- **Complexity**: One module, one method (`tryAcquire(): { ok: true } | { ok: false, retryAfterMs: number }`).
  Refill is "lazy" — we do NOT run a `setInterval` to top up the bucket; instead, on
  each `tryAcquire` we compute `tokens = min(burst, tokens + elapsed × rate)`. This is
  the canonical implementation and avoids interval-timer drift.
- **Correctness**: `process.hrtime.bigint()` is monotonic (unaffected by wall-clock
  jumps from NTP); `Date.now()` is not, but the spec only needs *forward progress*
  not absolute time. Either is acceptable; we prefer `hrtime` to defend against
  NTP-step madness on container hosts. Consistent state because Node's event loop
  serialises all callbacks.
- **Operability**: The module is fully unit-testable by injecting a clock function;
  no need for fake timers in tests.
- **Verdict**: chosen — the algorithm is simple, the spec's parameters fit it
  natively, and we own the source of every rounding decision (FR-7 demands two header
  values derived from the same instant).

### Alternative B: A library token bucket (e.g., `bottleneck`, `limiter`, `rate-limiter-flexible`)

- **Cost**: One more dependency, install size disproportionate to the 30 LOC saved.
- **Complexity**: Most libraries default to *queueing* requests until a token is
  available, which directly violates FR-7's "MUST NOT queue, buffer, or delay
  internally; rejection is immediate". Configuring some of them for fail-fast mode
  is possible but requires reading their source to be sure.
- **Correctness**: `rate-limiter-flexible` does support a "reject when empty" mode,
  but its `Retry-After` calculation is in seconds and we still have to compute
  `X-RateLimit-Reset-Ms` ourselves — at which point we have re-implemented half the
  bucket anyway.
- **Operability**: Library upgrade risk for a 30-LOC algorithm is asymmetric — we
  pay maintenance cost for negligible value.
- **Verdict**: rejected — most libraries optimise for queueing, which is exactly
  the wrong default for FR-7.

### Alternative C: Interval-driven bucket — `setInterval(() => tokens = min(burst, tokens + 1), 200)`

- **Cost**: Slightly more LOC plus an interval timer that lives forever.
- **Complexity**: Surface-easy ("tokens go up by 1 every 200 ms"), deceptively brittle.
- **Correctness**: `setInterval` is subject to event-loop lag — under a hot loop the
  interval can drift, so the actual refill rate dips under load. The bucket would then
  be *more conservative* than 5 RPS, leaking throughput. Worse, on container suspend
  / unsuspend (rare but real on cgroup throttling) the interval may fire many times
  in a row, briefly exceeding 5 RPS.
- **Operability**: Hard to test deterministically without fake timers; harder still
  to reason about during a live-locked event loop.
- **Verdict**: rejected — drifts under exactly the load profile we care about.

## Decision

We implement Alternative A. The bucket lives in a single module with the API:

```
class TokenBucket {
  constructor({ rate, burst, clock = process.hrtime.bigint }) { ... }
  // tryAcquire returns immediately. No await, no setTimeout, no I/O.
  tryAcquire(): { ok: true } | { ok: false, retryAfterMs: number }
}
```

`rate = 5` (per second), `burst = 5`. On each `tryAcquire`:

1. Read `now = clock()`.
2. `elapsedMs = Number(now - lastRefill) / 1e6`.
3. `tokens = min(burst, tokens + (elapsedMs / 1000) * rate)`. This is fractional
   on purpose — fractional tokens mean we can serve a request as soon as
   `tokens >= 1`, not only on quantised 200-ms boundaries.
4. If `tokens >= 1`: decrement `tokens -= 1`, set `lastRefill = now`, return
   `{ ok: true }`.
5. If `tokens < 1`: compute `retryAfterMs = ceil((1 - tokens) / rate * 1000)`,
   set `lastRefill = now` (so subsequent refill math is consistent), return
   `{ ok: false, retryAfterMs }`.

The Fastify handler invokes `tryAcquire` **after** FR-12 / FR-8 / FR-4 reject paths
(no point spending a token on a request we will reject anyway) and **before**
ADR-003's retry orchestrator. On `ok: false`:

- HTTP 429.
- `Retry-After: <ceil(retryAfterMs / 1000)>` (minimum 1, per FR-7 — this is the
  whole-second over-advise the spec acknowledges).
- `X-RateLimit-Reset-Ms: <retryAfterMs>` (the spec's millisecond-precision
  escape hatch for callers who can read it; FR-7 names this header).
- JSON error body `{ "error": { "type": "rate_limited", "message": "outbound capacity exhausted" } }`.
- `outcome=rate_limited` (NFR-OBS-1) for the request log line and metrics.

There is no internal queue. There is no `await`. There is no second chance —
on the next inbound request the bucket may have refilled, but the rejected
request is gone.

Interaction with ADR-002 (AbortController) and ADR-003 (retry orchestrator):

- The bucket is consumed *once per inbound request* (a single token covers the
  initial attempt + the optional FR-6 retry; we explicitly do **not** consume a
  second token on retry, because both attempts together are still serving a
  single caller request, and double-counting would halve effective throughput).
- The bucket is consumed *before* spending wall-time on backoff or upstream
  calls, so a busy bucket short-circuits the request fast (latency_ms < 5 ms,
  not 30 s).
- If the inbound caller's TCP has already closed by the time `tryAcquire` runs,
  the request is dropped (Fastify lifecycle handles this); the bucket is not
  consumed, because we check `request.raw.destroyed` immediately before
  `tryAcquire`.

This **contributes to objection 7** by pinning the local-overflow numbers:
`X-RateLimit-Reset-Ms` is an exact millisecond value drawn from the same
monotonic clock the bucket uses; `Retry-After` is the same value rounded up
to whole seconds with a 1-second floor. Callers that respect `X-RateLimit-Reset-Ms`
get tight scheduling; callers that respect only `Retry-After` get the
HTTP-spec-compliant over-advise.

## Consequences

### Positive

- 30 LOC, no dependency, deterministic to test (clock is injectable).
- FR-7 immediate-rejection is structural: there is no path through the module
  that awaits or queues.
- `Retry-After` and `X-RateLimit-Reset-Ms` come from the same instant — they
  cannot disagree.
- Fractional refill means burst recovery is smooth; no 200-ms quantisation
  artefacts at the boundary.

### Negative

- Process-local: NFR-CAP-1 explicitly notes that running ≥ 2 instances
  multiplies the effective rate. ADR-007's deploy procedure is the only thing
  that prevents this from happening (combined with FR-9 bind-or-die). If the
  procedure is ignored, the bucket gives wrong protection silently. This is
  exactly the failure mode of spec-review objection 3, addressed in ADR-007.
- Hand-rolled means we own the bug. Off-by-one in `retryAfterMs`, a sign error
  on `elapsedMs`, or a missed `lastRefill` update could go unnoticed in
  production. Mitigation: a property-based test that drives the bucket through
  randomised request schedules and asserts long-run rate matches `5/s ± ε`.
- 1-second `Retry-After` floor over-advises by up to 4×: at the edge of the
  bucket, the actual wait is 200 ms, but the rounded `Retry-After: 1` tells the
  caller to wait a full second. Callers that cannot read `X-RateLimit-Reset-Ms`
  see lower effective throughput than the bucket allows. This is the cost of
  HTTP/1.1 spec compliance and is explicitly accepted by FR-7.
- The bucket has no observability of its own (no `proxy_ratelimit_tokens` gauge
  in the spec). Operators see only the `outcome=rate_limited` counter, not how
  close to the cap the proxy is running. Adding such a gauge is a future
  iteration; the on-call sees the symptom, not the cause.

## Open questions

- Should the bucket emit a structured `WARN`-level log when it returns
  `ok: false`, in addition to the closing-line at NFR-OBS-1's `outcome=rate_limited`?
  The spec mandates exactly one log line per request (NFR-OBS-1); a separate
  WARN would violate that. The arch-reviewer may push to add a counter
  `proxy_ratelimit_tokens_available` gauge; we keep the surface minimal for
  now.
- The spec is silent on how the bucket interacts with the 30-second drain
  window (NFR-AVL-1). We assume the bucket continues to enforce the 5 RPS cap
  during drain; ADR-006 confirms this — the gauge `proxy_up` flips to 0 but
  the bucket still operates so in-flight requests do not stampede DeepSeek.
