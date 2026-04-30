# ADR-002: Use undici with per-attempt timeouts and AbortController for upstream calls

## Status

proposed

## Context

The proxy's upstream HTTP behaviour is the most failure-mode-rich part of the system:
it must split a single per-attempt budget into TCP-connect (3 s), first-byte (12 s),
and total-attempt (12 s) timeouts (NFR-LAT-2); it must propagate a wall-time abort
from the proxy's request handler all the way down to the upstream socket so that we
do not keep consuming DeepSeek bytes after returning 504 to the caller (NFR-LAT-1
mandatory abort propagation); it must forward both the request body and the response
body as opaque bytes (FR-3, FR-11); it must verify TLS by default and refuse to start
if `NODE_TLS_REJECT_UNAUTHORIZED` is `0` or `false` (FR-12 — handled in ADR-007 but
the choice of client matters because the wrong client makes it easy to bypass).

This ADR is the chosen implementation that **resolves spec-review objection 1**
(the 14 + 0.6 + 14 timing race had no abort-propagation contract) and contributes
to **objection 8** (no typed deserialization on the response side either).

- Drives: FR-3, FR-5 (Class A timing detection), FR-11, NFR-LAT-1, NFR-LAT-2,
  NFR-DEP-1.
- Resolves: spec-review objection 1 (abort propagation on wall-time expiry).
- Contributes to: spec-review objection 8 (response body is bytes, never `JSON.parse`d).

## Alternatives

### Alternative A: `undici.Pool` (or `undici.Client`) with `headersTimeout`, `bodyTimeout`, and an `AbortController` per attempt

- **Cost**: One dependency (`undici`) which is already in Node.js core (`globalThis.fetch`
  is `undici` under the hood); installing the explicit package adds API surface, not
  bytes.
- **Complexity**: Pool config is a single object (`connect.timeout = 3000`,
  `headersTimeout = 12000`, `bodyTimeout = 12000`). AbortController plumbing is one
  argument on `pool.request({ ... signal })`.
- **Correctness**: Three independent timeouts map directly onto NFR-LAT-2's three
  numbers. `AbortController.abort()` closes the upstream socket immediately and
  surfaces an `AbortError`, which we map to `gateway_timeout` (NFR-LAT-1). undici's
  pool keeps a small fixed number of TCP+TLS connections warm to a single host
  (`api.deepseek.com`), so connect-timeout fires only on cold/broken sockets, not on
  every request.
- **Operability**: undici exposes connect/read/write events we can wire into metrics
  if we ever need finer-grained latency breakdown. Failure modes have stable error
  codes (`UND_ERR_HEADERS_TIMEOUT`, `UND_ERR_BODY_TIMEOUT`, `UND_ERR_CONNECT_TIMEOUT`)
  that map cleanly onto FR-5 Class A vs mid-body distinctions.
- **Verdict**: chosen — only option that delivers the three NFR-LAT-2 timeouts as
  *separate* knobs, surfaces them as distinct errors, and integrates with
  AbortController without an extra wrapper.

### Alternative B: Global `fetch` (Node 20+ built-in) with `AbortController` and a wall-clock `setTimeout`

- **Cost**: Zero additional dependencies.
- **Complexity**: `fetch` exposes only one timeout knob — the `signal` — so all three
  NFR-LAT-2 timeouts collapse into hand-rolled timers (`setTimeout(controller.abort,
  3000)` for connect can't even be expressed: there is no "connected" event).
- **Correctness**: We cannot satisfy NFR-LAT-2 as written. Connect-timeout cannot be
  distinguished from first-byte-timeout. FR-5 Class A vs mid-body distinction collapses
  because by the time the abort fires we don't know whether response bytes had begun.
- **Operability**: The error after `controller.abort()` is a generic `AbortError`
  with no detail on which phase aborted; on-call cannot distinguish a DNS failure from
  a slow model.
- **Verdict**: rejected — collapses three spec-required timeouts into one, breaks the
  FR-5 cutoff classification.

### Alternative C: `node:https` raw with hand-coded socket and TLS event handlers

- **Cost**: Zero dependencies.
- **Complexity**: Maximum. We would re-implement keep-alive pooling, retries, TLS
  session resumption, and response chunk plumbing — hundreds of lines, every one a
  potential FR-11 violation.
- **Correctness**: In principle the most precise control over NFR-LAT-2 (we can hook
  `socket` 'connect', 'secureConnect', 'data' events). In practice the test surface to
  validate the same is large.
- **Operability**: We own every bug. Node-LTS HTTP/HTTPS stack changes (Node 22 → 24)
  hit our code first.
- **Verdict**: rejected — operating cost dwarfs the gain over `undici`.

## Decision

We use **`undici.Pool`** as the single shared upstream client, configured at startup
with:

- `connect: { timeout: 3000 }` — NFR-LAT-2 TCP+TLS connect timeout.
- `headersTimeout: 12000` — NFR-LAT-2 first-byte timeout.
- `bodyTimeout: 12000` — NFR-LAT-2 total per-attempt timeout (interpreted as
  inactivity-while-reading-body; combined with `headersTimeout` it caps the attempt).
- `keepAliveTimeout: 30000`, `pipelining: 1`, `connections: 8` — small fixed pool to
  amortise TLS handshakes across the NFR-CAP-2 forecast load (< 3 RPS).
- `connect.rejectUnauthorized: true` — explicit re-affirmation; the actual TLS guard
  on `NODE_TLS_REJECT_UNAUTHORIZED` is enforced at boot in ADR-007.

Each attempt is wrapped in a per-request **`AbortController`** whose `signal` is
passed to `pool.request({ signal })`. The same controller is wired to:

1. The wall-time guard (NFR-LAT-1): a `setTimeout(controller.abort, remainingWallTime)`
   armed at attempt start, where `remainingWallTime` = `30 000 ms − (Date.now() − requestStart)`.
2. The retry orchestrator (ADR-003): on the second attempt, a fresh AbortController
   is created with `remainingWallTime` recomputed.
3. The inbound caller's connection: if the caller's TCP closes (Fastify
   `request.raw.on('close')`), we abort the controller — there is no point continuing
   to spend DeepSeek quota for a caller who has hung up.

When the controller aborts, undici closes the upstream socket synchronously; we MUST
NOT iterate the response body afterwards. The proxy returns 504 Gateway Timeout
(`outcome=gateway_timeout`) to the caller and increments `proxy_upstream_status_total`
only if response bytes had started arriving (otherwise the metric is unchanged, per
NFR-OBS-1's "transport-only failures do not increment").

Error mapping for FR-5 classification:

- `UND_ERR_CONNECT_TIMEOUT`, DNS errors, ECONNREFUSED / ECONNRESET / EHOSTUNREACH /
  ENETUNREACH, TLS handshake errors, `UND_ERR_HEADERS_TIMEOUT` → **Class A** (retry
  eligible per FR-5).
- `UND_ERR_BODY_TIMEOUT` or socket reset *after* `headers` event → mid-body
  transport failure, **NOT retried** (FR-5 cutoff), surfaces as `transport_error`
  with HTTP 502 to caller.
- `AbortError` from wall-time → `gateway_timeout`, 504 to caller, no retry.

This decision **directly resolves spec-review objection 1**: when wall-time fires,
`controller.abort()` closes the socket; no further upstream bytes are consumed; no
double-bill exposure beyond what DeepSeek had already processed before the abort.
The 1.4 s headroom from the spec's arithmetic is no longer load-bearing because the
wall-time guard is mandatory and observable.

## Consequences

### Positive

- Three independent NFR-LAT-2 knobs map onto three undici settings, not onto a
  single collapsed timeout.
- AbortController propagation is end-to-end: caller close → abort upstream; wall-time
  fire → abort upstream; retry orchestrator → new controller on attempt 2.
- Class A vs mid-body classification (FR-5 cutoff) falls out of distinct undici
  error codes; the retry orchestrator (ADR-003) consumes a typed enum, not a string
  match.
- Pool reuse keeps TLS handshake cost off the hot path at NFR-CAP-2 traffic levels.

### Negative

- We pin a non-core dependency for a Node.js version that ships `fetch` natively,
  paying an upgrade tax across Node 20 / 22 LTS lifecycles. Mitigation: undici tracks
  Node releases closely.
- undici error codes are a moving target across versions; the FR-5 classification
  table needs a regression test that pins each `UND_ERR_*` we depend on. We accept the
  test maintenance burden.
- AbortController's `abort()` is fire-and-forget at the socket level — there is a
  small window (< event-loop-tick) where the kernel may have already buffered upstream
  bytes that we then discard, which still cost DeepSeek a partial response. Within
  that window the proxy has paid for bytes it does not return; the spec accepts this
  as the practical floor of "no continued consumption after 504."
- `connections: 8` is a guess. Too low → head-of-line waits at peak; too high → idle
  TCP / TLS state. NFR-CAP-2 forecast (3 RPS peak, 12 s p99) means a working set of
  ~36 in-flight upstreams in worst case; 8 is sized for the 5 RPS *outbound* cap,
  not the inbound peak (since outbound is rate-limited to 5/s). Operator may need to
  retune if the forecast is wrong; flagged below.

## Open questions

- Pool sizing at 8 connections is an educated guess sized to NFR-CAP-1 (5 RPS, burst
  5). Should this be `PORT`-style configurable env, or hard-coded? We hard-code for
  now (consistent with the spec's "fixed for this iteration" clause on caps), and
  flag it for the arch-reviewer to challenge.
- `bodyTimeout` is "inactivity timeout while streaming the body", not "total elapsed
  on the body". For non-streaming responses (FR-4 defers `stream:true`), the
  distinction collapses, but if a future iteration enables SSE we will need to revisit
  whether this maps to NFR-LAT-2's "total per-attempt 12 s" semantics.
