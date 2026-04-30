# ADR-005: pino + prom-client on a separate metrics port, with redaction and AsyncLocalStorage correlation

## Status

proposed

## Context

NFR-OBS-1 specifies the observability surface in detail: structured JSON logs
to stdout (one line per inbound request, fixed field set), Prometheus metrics
on a separate port (FR-9: default 9090), and a closed `outcome` enum. NFR-SEC-1
and the amended NFR-SEC-1 prose explicitly forbid the upstream API key from
appearing on any log path, including incidental error serialisation. FR-10
requires the proxy-assigned `request_id` to be returned in every response as
`X-Request-Id` and to match the value logged.

The choice of logger and metrics library affects three things at once:
performance under NFR-CAP-2 (negligible at < 3 RPS but the redaction config is
not), redaction safety (NFR-SEC-1 secret-in-logs prohibition is the highest-cost
defect we could ship), and FR-10's request_id correlation across nested
function calls.

This ADR **resolves spec-review objection 10** (metrics port, `proxy_up`
gauge, `proxy_build_info`, upstream-status counter, histogram bucket layout)
and **partly resolves objection 2** (source IP and User-Agent are now logged).
It also **resolves objection 6** (X-Request-Id response header on every
response) and contributes to **objection 11** (upstream_request_id field;
deferred minor, captured in open questions).

- Drives: NFR-OBS-1, NFR-SEC-1, FR-9 (metrics port), FR-10 (X-Request-Id),
  NFR-AVL-1 (`proxy_up` flip).
- Resolves: spec-review objection 10 (full metrics surface).
- Resolves: spec-review objection 6 (X-Request-Id).
- Contributes to: spec-review objection 2 (source_ip, user_agent attribution).
- Defers: spec-review objection 11 (upstream_request_id; flagged in
  Open questions).

## Alternatives

### Alternative A: `pino` for logs + `prom-client` for metrics, request_id propagated via `AsyncLocalStorage`

- **Cost**: Two well-known dependencies; both are tiny, both are Node-LTS-grade.
- **Complexity**: pino's `redact` config takes a list of paths (`['req.headers.authorization', '*.headers.authorization', 'err.config.headers.Authorization']`)
  and substitutes `[Redacted]`. AsyncLocalStorage is a Node core API, so the
  correlation context costs zero deps.
- **Correctness**: pino is fast enough that the redaction guard is the bottleneck,
  not throughput; `prom-client` provides the histogram + counter + gauge primitives
  the spec names; AsyncLocalStorage propagates `request_id` through every nested
  await without a manual `ctx` parameter, so the log line emitted from a deep
  helper still has the right id.
- **Operability**: pino's child-logger pattern lets us attach `request_id` once at
  request start; the `outcome=...` final log line is one `request.log.info({ ... })`
  call. prom-client's `register.metrics()` is the body of `/metrics`.
- **Verdict**: chosen — best-in-class on the two axes that matter
  (redaction safety + correlation), low maintenance.

### Alternative B: `winston` + `prom-client`, request_id passed explicitly through call args

- **Cost**: Same dependency footprint.
- **Complexity**: Winston's redaction is not first-class — most teams use a
  `format.printf` to filter; subtle bugs in the formatter leak the secret.
  Passing `request_id` as a function argument adds a parameter to every helper.
- **Correctness**: Higher risk of NFR-SEC-1 violation: Winston has historically
  shipped CVEs around object serialization and prototype pollution; pino's
  redaction is `JSON.stringify`-time, deeper integrated.
- **Operability**: Threading `request_id` manually means a forgotten function
  argument silently emits a log line with `request_id: undefined`; the bug is
  invisible until the on-call tries to grep for an id.
- **Verdict**: rejected — slower, less safe redaction story, worse correlation
  ergonomics.

### Alternative C: `console.log` + a hand-rolled metrics endpoint that builds the Prometheus exposition format manually

- **Cost**: Zero dependencies.
- **Complexity**: Every log call must build the JSON line itself; redaction is
  an open-coded check on every log site (one missed site = leaked key); the
  Prometheus exposition format is plain text but we own labelling, escaping, and
  the histogram math.
- **Correctness**: Histogram math (cumulative bucket counts, `+Inf` bucket,
  `_sum` and `_count`) is a thing that's easy to get wrong; bugs surface as
  Grafana panels showing nonsense p99s.
- **Operability**: We own every line.
- **Verdict**: rejected — re-implementing observability primitives is
  exactly the wrong place to save dependencies.

## Decision

We adopt **`pino` 9.x** + **`prom-client` 15.x**. Concretely:

**Logger configuration.** Single root logger:

```
pino({
  level: process.env.LOG_LEVEL ?? 'info',
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers["proxy-authorization"]',
      '*.headers.authorization',
      '*.headers["proxy-authorization"]',
      'config.headers.Authorization',         // catches undici error objects
      'config.headers.authorization',
      'request.headers.authorization',
      'response.headers.authorization',
      'apiKey', 'api_key', 'DEEPSEEK_API_KEY',
    ],
    censor: '[Redacted]',
  },
  base: { service: 'deepseek-client', version: process.env.BUILD_VERSION ?? '0.0.0' },
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: { level: (l) => ({ level: l }) },
})
```

The redact list is broad on purpose. Any future code path that serialises an
undici request, a Node fetch error, or an env-var dump benefits without code
changes. We accept the small CPU cost of the JSON.stringify-time scan.

**Request correlation via AsyncLocalStorage.** A single
`AsyncLocalStorage<RequestContext>` instance is set on Fastify `onRequest`
and reset on `onResponse`. `RequestContext` carries:

- `request_id` (ULID, `monotonic` factory; ULIDs are time-sorted and shorter
  than UUIDs, easier to grep, lower log overhead). Format choice: ULID over
  UUIDv4 for grep-ability and time-sortedness, over cuid2 for LTS popularity.
- `requestStart` (BigInt monotonic, for latency_ms math).
- `outcome` (filled in on each branch end before the closing log line).

**Per-request log line on `onResponse`** (NFR-OBS-1 fields verbatim):

```
{
  "level": "info",
  "time": "2026-04-30T03:14:22.819Z",
  "request_id": "01HW1J4...",
  "status": 200,
  "latency_ms": 472,
  "upstream_latency_ms": 461,
  "upstream_status": 200,
  "retry_count": 0,
  "outcome": "ok",
  "source_ip": "10.4.1.17",
  "user_agent": "deepseek-sdk/0.7.1",
  "service": "deepseek-client",
  "version": "1.4.0"
}
```

`source_ip` is `request.ip` (Fastify's parse of the TCP peer address; spec
accepts that this is the LB's IP behind a load balancer).

**FR-10 X-Request-Id.** Set on `onRequest` after the ULID is minted:
`reply.header('X-Request-Id', ctx.request_id)`. Emitted on every response,
success or error, including the 411 / 413 / 415 / 405 / 404 paths and the
local-429 fast-fail. Caller-supplied `X-Request-Id` is ignored, per FR-10.

**Metrics on a second Fastify instance bound to `METRICS_PORT`.** Endpoints:

- `GET /metrics` → `register.metrics()` exposition format.
- `GET /healthz` → `{"status": "ok"}` while `proxy_up == 1`, 503 while drain
  is in progress (interaction with ADR-006).

**Concrete prom-client registrations:**

- `proxy_requests_total` — `Counter`, label `outcome` ∈
  {`ok`, `rate_limited`, `gateway_timeout`, `upstream_5xx`, `transport_error`,
  `client_error`}. The set is closed at registration time (we pre-register
  zeros for each label so the metric appears immediately on `/metrics`, not
  only after the first occurrence — important for alert "no data" handling).
- `proxy_upstream_status_total` — `Counter`, label `status` (string). This
  counter is what spec-review objection 5 / 10 demanded: it makes 500 vs 502
  vs 503 vs 504 distinguishable on the dashboard without log greps.
- `proxy_request_duration_ms` — `Histogram`, no labels. Buckets:
  `[1, 10, 100, 250, 500, 1000, 2000, 5000, 10000, 12000, 30000]` — the spec's
  exact mandated layout from NFR-OBS-1.
- `proxy_up` — `Gauge`, `1` healthy, `0` during drain.
- `proxy_build_info` — `Gauge` (always `1`), labels `version` and `git_sha`
  read from build-time env. This is the "is the right version live"
  liveness alert anchor.

**No tracing.** Confirmed out of scope per spec.

## Consequences

### Positive

- NFR-SEC-1 secret-in-logs prohibition is structural: pino's redact runs at
  serialisation time on every log object, so even an `error.config.headers`
  dump from undici is sanitised without code changes.
- AsyncLocalStorage means every helper, every nested promise, every error
  callback has the right `request_id` without an explicit `ctx` parameter.
  The on-call greps once and gets every line for the incident.
- prom-client's exposition format is correct by construction (cumulative
  buckets, `_sum`, `_count`); we do not own the parser-side compatibility.
- Pre-registering all `outcome` label values makes the alerting story sane
  ("no data" vs "0" disambiguation).
- Source IP + User-Agent in every log line addresses spec-review objection 2's
  attribution complaint.
- `X-Request-Id` on every response addresses spec-review objection 6's
  caller-side support story.

### Negative

- pino's redact mechanism is path-based, not value-based: a future code path
  that puts the API key in a *different* field (e.g. `metadata.token`) silently
  evades redaction. Mitigation: the redact list includes `apiKey`, `api_key`,
  and `DEEPSEEK_API_KEY` as defensive aliases; we will add a *grep test* in CI
  that scans test-environment log output for the literal value of a fake test
  key and fails the build if it appears. The grep test is not in the spec; it
  is a derived control we accept the cost of.
- ULIDs are 26 chars; UUIDv4 is 36. Either is fine, but operators trained on
  UUIDs will need a quick note in the runbook that `01HW...` is the id format.
- `proxy_upstream_status_total{status}` cardinality is bounded by the universe
  of HTTP status codes (~70), but a malicious or buggy upstream returning
  unusual statuses (`418`, `599`) would still increment those labels. We accept
  the unbounded-in-theory cardinality because the upstream domain is
  controlled (DeepSeek alone, FR-2).
- Two Fastify listener instances mean two separate event loops? No — Fastify
  shares the event loop; but two separate `server.close()` paths must be
  coordinated on shutdown (ADR-006). One more thing to remember.
- Histogram buckets cover the spec's exact layout, but not the pathological
  outlier (3 ms p50 vs 30 000 ms p99 spans 10 000×); the bucket spacing is
  uneven on purpose to capture the boundary regions. Operators who want a
  different layout will need to amend the spec, not the ADR.

## Open questions

- spec-review objection 11 (deferred minor) wants `upstream_request_id`
  captured from a small allow-list of upstream response headers
  (`x-request-id`, `x-deepseek-request-id`, `cf-ray`). The spec's current text
  treats this as deferred; the implementation can be retrofitted as a
  one-field addition to the per-request log without re-architecting. We
  flag for the arch-reviewer: should this ADR pre-emptively read those
  headers and add the field as `null` until the next iteration?
- The closed `outcome` enum has six values, but spec-review objection 10
  asks "which outcomes can co-occur with which HTTP statuses". We have not
  written this matrix into a metric label intentionally — the
  `proxy_upstream_status_total` counter and the per-request log line make
  the join recoverable. The arch-reviewer may push for an `outcome` ×
  `status` cross-tab; we resist for cardinality reasons.
- ULID vs UUIDv7 (RFC 9562, time-ordered UUID): UUIDv7 is the newer
  standardised time-ordered alternative. We pin ULID for stability of the
  format across Node versions (no Node-core implementation of UUIDv7 in
  Node 20); the arch-reviewer may push to switch to UUIDv7 in Node 22.
