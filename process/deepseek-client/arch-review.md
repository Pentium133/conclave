# Architecture review: deepseek-client

> Reviewer stance: it is 3am, this thing is on fire, walk me through how it
> failed. Every paragraph below names a specific failure mode, a missing signal,
> or a concrete follow-up. The reviewer has not read `spec-review.md` and is
> forming an independent view from spec.md + the seven ADRs only.

## Per-ADR review

### ADR-001: Use Fastify with raw-body handling for the inbound HTTP surface

- **Verdict**: challenge
- **Arguments** (≥3 concrete, technical, citing FR/NFR-IDs and trade-off axes):
  - **FR-4 stream-detection by substring is correctness-fragile.** The decision
    section says "after the buffer is captured (under the 256 KiB cap), we run a
    substring check for the literal token `"stream":true`/`"stream": true`
    against the raw bytes". A perfectly valid JSON request body containing
    `"system": "Reply with the literal text \"stream\":true at the start"` (a
    user prompt that mentions the field name) will be rejected with HTTP 400 by
    a substring match — a false-positive FR-4 violation that breaks the FR-3
    drop-in compatibility guarantee. The ADR text explicitly states "No
    `JSON.parse`" and offers no protection against this. Trade-off axis hit:
    `correctness` is sacrificed for `complexity` minimisation. The spec explicitly
    permits "a streaming JSON tokenizer" as the safer alternative; the ADR
    chose the brittle one without arguing why.
  - **FR-12 415 enforcement is bound to a Fastify behaviour the ADR's own
    "Negative consequences" admits could change in a minor version.** The
    decision is "a Fastify minor that loosened the matcher would silently widen
    our 415 contract". The mitigation is "an integration test that POSTs
    `text/plain` and asserts 415 is mandatory". An integration test catches the
    regression in CI; it does not protect a production deploy from a Renovate
    auto-merged Fastify minor that escapes the test (e.g. a charset-parameter
    edge case the test does not cover). For a perimeter-trusted but
    quota-exposed proxy (NFR-SEC-2: anyone reachable can drain the bill), a
    silent 415 widening that lets `Content-Type: text/html` requests through
    means a buggy caller can spike the DeepSeek bill. Trade-off axis hit:
    `operability` (the upgrade path is not in our hands) and `correctness` are
    coupled to a third-party library's release notes.
  - **The 411-on-missing-Content-Length policy has no body-buffering protection
    if Fastify accepts the request first.** ADR-001 says "We will add an
    `onRequest` hook to enforce 411, but a future Fastify behaviour change could
    surprise us". `onRequest` fires before body parsing, but Fastify's default
    body-parser starts consuming bytes as soon as the route resolves; if the
    onRequest hook returns the 411 response after the parser has already begun
    reading the chunked body, an attacker can OOM the proxy by streaming
    gigabytes into a chunked POST. Combined with NFR-DEP-2's recommended 512
    MiB container limit, that is a one-line DoS. The ADR does not name a hard
    `request.raw.destroy()` after the 411 reply, which is the only thing that
    stops the upstream from continuing to feed bytes.
- **3am production failure scenarios** (≥2):
  - **Scenario 1: false-positive stream rejection breaks a customer.** A
    caller's prompt asks DeepSeek to "explain how Server-Sent Events differ
    from WebSockets — include the line `"stream": true` in your response". The
    proxy's substring scan in the inbound buffer matches the prompt content,
    rejects with HTTP 400, and the caller files a P1 ticket at 3am because
    their nightly batch job is failing on every retry. On-call sees: a spike in
    `client_error` outcome with `status=400`, no upstream call, no `request_id`
    correlation to a real failure. Root cause is invisible without inspecting
    the request body — which NFR-OBS-1 forbids logging. The on-call cannot
    even confirm the diagnosis without enabling a debug log path that the spec
    forbids in production.
  - **Scenario 2: Fastify v4 → v4.x minor upgrade widens 415 contract under
    Renovate.** A weekly Renovate PR auto-merges `fastify@4.31.x → 4.32.x`. The
    new minor relaxes Content-Type matching to accept `application/json;
    boundary=...` (a malformed parameter the parser previously rejected with
    415). At 3am, a buggy CI script POSTs `Content-Type: application/json;
    boundary=foo` with non-JSON bytes; the proxy now forwards to DeepSeek,
    which 400s with `invalid JSON`; the caller retries; DeepSeek bills accrue.
    On-call sees: a sudden uptick in `proxy_upstream_status_total{status="400"}`
    with no obvious deploy correlation. The 415-regression integration test in
    CI did not cover this charset-parameter shape and so did not block the
    upgrade. There is no metric for "request that should have been 415 but
    wasn't"; the signal is "DeepSeek bill went up".
- **Operational problems**:
  - No metric for "stream-detection rejected request" vs "Content-Type
    rejected request" vs "size-rejected request" — all three collapse into
    `outcome=client_error`. On-call cannot triage which FR is firing without
    log greps on `status=400/413/415/411` separately.
  - The 411-vs-413 distinction is in the per-request log line `status` field
    only. A spike in 411s means a misconfigured caller; a spike in 413s means
    an overlarge prompt. The dashboards described in ADR-005 surface these as
    one number (`client_error` counter) and the on-call must grep stdout to
    distinguish them.
  - No documented playbook for the "Fastify minor breaks 415" regression. The
    ADR names the risk and trusts a single integration test to catch it.
- **Disagree-flag (MANDATORY)**:
  - `I disagree with: the FR-4 stream-detection-by-substring decision. The
    spec explicitly offers a streaming JSON tokenizer as an acceptable
    alternative; the ADR chose the substring path for "complexity minimisation"
    but the substring path has a deterministic false-positive class
    (any prompt content containing the literal "stream":true text) that breaks
    FR-3 drop-in compatibility and produces a 400 the caller cannot diagnose
    without body logging (which NFR-OBS-1 forbids). A streaming tokenizer
    that scans only the top-level "stream" field — checked against the first
    few KiB before accepting the rest — is bounded-cost and correctness-clean.
    The ADR should be revised to mandate the tokenizer path or, at minimum,
    require the substring scan to be limited to the JSON's top-level keys
    (e.g. by tokenising up to the first `,` at brace-depth 1).`

### ADR-002: Use undici with per-attempt timeouts and AbortController for upstream calls

- **Verdict**: challenge
- **Arguments**:
  - **`bodyTimeout` is an inactivity timeout, not a wall-time timeout, and the
    ADR admits this in Open questions.** The "Negative" section says
    "`bodyTimeout` is 'inactivity timeout while streaming the body', not 'total
    elapsed on the body'". For non-streaming responses it works. But DeepSeek
    can return a 50 KiB response body slowly (10 ms gaps between every TCP
    chunk); each gap is below `bodyTimeout=12000`, so undici keeps reading,
    and the total per-attempt time blows past NFR-LAT-2's "12 s total
    per-attempt" by an unbounded amount. The wall-time guard at 30 s in
    ADR-002's `setTimeout(controller.abort, remainingWallTime)` is the only
    backstop; if it is set after `pool.request` returns headers (see "after
    `headers` event" in the FR-5 mapping), the per-attempt budget can be
    silently exceeded. NFR-LAT-2 is violated on the wire; the proxy reports
    the right `latency_ms` but the per-attempt invariant the spec promises is
    not enforced in undici, only at the wall-time horizon.
  - **`connections: 8` pool sizing is mis-sized for the actual concurrency
    envelope.** ADR-002's own analysis says "NFR-CAP-2 forecast (3 RPS peak,
    12 s p99) means a working set of ~36 in-flight upstreams in worst case;
    8 is sized for the 5 RPS *outbound* cap, not the inbound peak". This is
    fine when `outbound = 5 RPS` and `attempt_p99 = 12 s` give working set =
    `5 × 12 = 60 in-flight`. With 8 connections, requests #9..#60 wait in
    undici's internal queue, adding hidden latency that the per-attempt timer
    does not account for (the timer starts when `pool.request` resolves the
    socket, not when it is enqueued). On a TCP-reset storm where DeepSeek
    drops every connection, undici reopens 8 sockets, each taking ~3 s for
    TLS handshake; 60 in-flight requests serialise and the wall-time guard
    fires for nearly all of them. This is a `gateway_timeout` storm caused by
    the pool, not the upstream. Trade-off axis hit: `cost / complexity`
    (small fixed pool) at the expense of `correctness` under failure load.
  - **Caller-close → upstream-abort coupling makes the proxy a useful tool
    for bill suppression at the cost of unintentional retries.** The decision
    says: "if the caller's TCP closes (Fastify `request.raw.on('close')`), we
    abort the controller — there is no point continuing to spend DeepSeek
    quota for a caller who has hung up." This sounds defensive, but combined
    with FR-5 retry semantics, it creates a footgun: a flaky load balancer
    between the caller and the proxy that silently hangs up the inbound
    socket mid-request will cancel the upstream call. The caller may have
    seen no error yet (the LB will retry), so it issues a retry through the
    LB, hits the same proxy, and a second DeepSeek call is initiated. The
    first call was already consuming model time before the abort. Net: one
    caller-perceived request, two DeepSeek bills. NFR-OBS-1 records this as
    two `request_id`s with `outcome=ok` (or one `gateway_timeout` + one `ok`),
    but the correlation between them is lost because FR-10 explicitly does
    NOT honour caller-supplied `X-Request-Id`. On-call sees a 2× bill
    unaccountable to any single request_id.
- **3am production failure scenarios**:
  - **Scenario 1: DeepSeek edge LB slow-drip causes per-attempt timeout
    bypass.** DeepSeek's edge CDN under partial degradation returns response
    bytes at 100 ms intervals. Each chunk is below `bodyTimeout=12000`, so
    undici keeps reading. The total time-to-last-byte for a 30 KiB response
    is 30s. The wall-time guard fires at 30 s, returns 504 to the caller,
    aborts the socket. `latency_ms=30000`, `upstream_latency_ms=30000`,
    `outcome=gateway_timeout`. On-call sees a flat line of 30-s requests on
    the histogram p99 panel; root cause is a slow upstream that NFR-LAT-2
    "should" have cut off at 12 s, but undici did not.
  - **Scenario 2: TCP-reset storm + small pool = pile-up of `gateway_timeout`.**
    DeepSeek's upstream restarts a load balancer fleet, RSTs every active
    connection. The proxy's 8-connection pool starts handshakes 8 at a time;
    each takes 2.5 s. Inbound load at the steady-state forecast (1 RPS) means
    24 requests pile up in the undici queue during the first 30 s. The first
    8 succeed at ~5 s, the next 8 at ~10 s, the next 8 are waiting at 15 s
    queue-time and now have only 15 s of wall-time remaining. At 30 s wall
    each pending request fires `controller.abort` while still in the queue.
    On-call sees: a 30-s spike in p99, `proxy_requests_total{outcome=gateway_timeout}`
    counter goes up, but `proxy_upstream_status_total` does not increment for
    the queued aborts (transport-only failures), so the dashboard shows
    "everything is timing out" with no upstream attribution. There is no
    `proxy_upstream_pool_pending` gauge to confirm the queue depth as the
    cause.
- **Operational problems**:
  - No metric for `undici.Pool` queue depth, active connections, or pending
    requests. NFR-OBS-1 names six metrics; pool health is not among them.
    On-call cannot tell "we are pool-saturated" vs "DeepSeek is slow".
  - No metric breakdown for the FR-5 Class A subcategories. The ADR documents
    a beautiful mapping (UND_ERR_CONNECT_TIMEOUT vs DNS errors vs ECONNRESET
    vs TLS handshake) but at the metric level all collapse into
    `outcome=transport_error` (and the upstream-status counter is unincremented).
    Diagnosing "is it DNS, is it TLS, is it the upstream LB" requires log
    greps on the `request_id` field, not dashboards.
  - The runbook for "raise pool size" is absent. Operators don't know what
    knob to turn when the queue is the culprit.
- **Disagree-flag (MANDATORY)**:
  - `I disagree with: hardcoding connections: 8 with no metric for pool
    queue depth and no documented runbook for the failure-mode where the
    inbound peak × p99 latency exceeds the pool size. The Open questions
    section flags this for the arch-reviewer; my recommendation is (a) make
    the pool size configurable via an env var (POOL_CONNECTIONS, defaulting
    to 8), (b) add a proxy_upstream_pool_pending gauge to NFR-OBS-1, (c)
    document a runbook entry "if proxy_upstream_pool_pending > 0 sustained,
    raise POOL_CONNECTIONS". The ADR's analysis itself shows the working
    set could be 36; shipping 8 with no signal for the saturation is a
    capacity footgun.`

### ADR-003: Implement retry policy as a stateless orchestrator with two failure classes

- **Verdict**: challenge
- **Arguments**:
  - **The "Retry-After: 0 on absent/malformed" decision combined with `Math.random()` jitter creates a thundering-herd against DeepSeek's edge.** FR-6 says backoff is 500 ms ± 20% for Class A; the ADR says
    Retry-After parser returns `0` for absent/malformed values on Class B.
    When DeepSeek's edge LB is mid-restart and returns 502 with no `Retry-After` header, every concurrent in-flight retry fires at `delay = 0`, all
    aimed at the same edge. NFR-CAP-1's outbound bucket caps the rate at 5
    RPS so this is bounded — but only at the bucket layer; the retries
    themselves all fire at the same millisecond, contend for the same 5
    tokens, and produce a bursty pattern that defeats the very purpose of
    jitter. The ADR's own Open questions flags this ("the arch-reviewer may
    push for a small fallback (e.g., 200 ms) to avoid exactly-back-to-back
    attempts"); my read is the arch-reviewer must push.
  - **`Math.random()` is not cryptographically uniform across cores under
    Node 22's V8.** Not a security issue, but `Math.random()` in a busy
    event loop can produce locally-correlated values when many backoffs are
    drawn within the same V8 internal cache window. Combined with the FR-6
    range of [400, 600] ms (only ±100 ms variance around 500 ms), the
    practical synchronisation between concurrent retries can be tighter than
    the spec intends. Trade-off axis hit: `correctness` of the
    storm-prevention property of jitter is undermined by a low-quality RNG
    choice the ADR makes implicit.
  - **The orchestrator's wall-time short-circuit ("if cap ≤ 0, forward the
    original 502/503") is silent in metrics.** The ADR's Negative section
    admits "the caller sees an `upstream_5xx` outcome with no retry having
    been attempted... on-call metrics will show an 'apparent' retry-budget
    burn when in fact the budget was never used". On-call has no signal to
    distinguish "we retried and failed" from "we never retried because the
    budget was already spent". `retry_count` in the log is `0` in both
    cases (when no retry was attempted) and `1` after a retry. There is no
    `retry_skipped_due_to_walltime` counter in NFR-OBS-1 or in this ADR.
- **3am production failure scenarios**:
  - **Scenario 1: synchronised retry storm against a flapping DeepSeek edge LB.**
    DeepSeek's edge fleet enters a 30-second flap where 50% of the
    instances return 502 with no `Retry-After`. Inbound load is at peak
    (3 RPS, NFR-CAP-2). Every 502 triggers an immediate retry (delay=0).
    The retry hits a different (or same) edge instance; if it is healthy
    the request succeeds; if 502 again, it is forwarded. NFR-CAP-1's bucket
    smooths this to 5 RPS outbound, but the retries fire in a single tight
    burst at the millisecond an entire batch's first attempts return 502.
    On-call sees: `proxy_upstream_status_total{status="502"}` doubling
    (initial + retry), `proxy_requests_total{outcome=upstream_5xx}` rising.
    The cause — synchronised retry without backoff — is invisible because
    `retry_count` in logs averages 1.0 (the desired retry rate) and the
    histogram p99 goes up but not catastrophically. The fix (add jitter to
    Class B too) requires a code change at 3am.
  - **Scenario 2: budget-exhausted-no-retry incident is misdiagnosed as a
    retry-policy bug.** A caller request arrives 28 s into a problem; first
    attempt takes 8 s, returns 502; the orchestrator computes
    `cap = remaining(22 s) − ATTEMPT_BUDGET(12 s) = 10 s`, which is ≥ 0,
    so a retry is permitted; the retry takes 4 s and also returns 502; the
    orchestrator forwards to caller. `retry_count=1`, `outcome=upstream_5xx`,
    `latency_ms=12500`. Now another caller arrives 5 s into a similar
    problem; first attempt takes 16 s (close to NFR-LAT-2's 12 s cap, hit
    by the headers timeout, eligible for Class A retry); the orchestrator
    computes `remaining = 30 − 16 = 14 s`; `jitterMs = 500`; `14 - 12 =
    2 s`; jitter (500 ms) ≤ 2 s, so retry proceeds; retry hits its own
    headers-timeout at 12 s, total 28.5 s, then wall-time fires at 30 s
    and the caller gets 504. The on-call sees TWO different patterns
    (`upstream_5xx` and `gateway_timeout`) for what is essentially "DeepSeek
    is slow + flaky"; without a retry-skipped counter, the operator
    cannot tell whether the policy is misbehaving or the upstream is.
- **Operational problems**:
  - No counter for "retry attempted" vs "retry skipped due to wall-time" vs
    "retry skipped due to upstream Retry-After exceeding budget". `retry_count`
    is binary (0 or 1); the *reason* for 0 is invisible.
  - The data-form FR-5 classification table (open question) is the right
    answer; without it, the dependency between ADR-002's undici error codes
    and ADR-003's branches is hidden in a switch statement.
  - No metric for the upstream `Retry-After` value distribution. If
    DeepSeek starts returning `Retry-After: 5` consistently, the proxy
    observes this latency hit but does not surface it as a metric — only
    as an aggregate p99 increase.
- **Disagree-flag (MANDATORY)**:
  - `I disagree with: defaulting Retry-After-absent and Retry-After-malformed
    to 0 (immediate retry). The Open question flags this for the
    arch-reviewer; my position is that the 0 default produces synchronised
    retries on edge-LB flaps and there is no signal to detect this in
    NFR-OBS-1's metrics. The fallback should be the same 500 ms ± 20%
    jitter used for Class A, both for storm-prevention and for behavioural
    parity between the two retry paths. The amended spec did not pick 0 —
    it permitted "FR-6 backoff applies" when Retry-After is absent; the
    ADR's "0 for absent/malformed" reading is at best a non-obvious
    interpretation and at worst a straight contradiction of FR-6.`

### ADR-004: Hand-rolled in-process token bucket for outbound rate limiting

- **Verdict**: accept (with reservations recorded below)
- **Arguments**:
  - **Algorithm and clock choice are correct.** `process.hrtime.bigint()` for
    monotonicity, lazy refill with fractional tokens, single-threaded JS
    serialisation, and injectable clock for tests are textbook correct for
    NFR-CAP-1's burst-of-5/5-RPS cap. The decision to consume one token per
    *inbound request* (covering the optional retry as well) is correct
    because double-counting would halve the user-visible throughput.
    Trade-off axes: `complexity` (30 LOC, no dep) and `correctness`
    (deterministic, testable) both maximised.
  - **FR-7 immediate-rejection invariant is structural.** The decision says
    "There is no internal queue. There is no `await`. There is no second
    chance." This is the right shape for the spec's "MUST NOT queue, buffer,
    or delay internally" requirement. A library would have offered a queueing
    default and a second-chance retry that the operator must remember to
    disable.
  - **Header-value derivation from the same instant is correct.** The ADR
    pins `X-RateLimit-Reset-Ms = retryAfterMs` and
    `Retry-After = ceil(retryAfterMs / 1000)`, so both come from the same
    bucket-state read. The HTTP-spec-compliant 1-second floor is acknowledged
    as a known over-advise.
- **3am production failure scenarios**:
  - **Scenario 1: `proxy_ratelimit_tokens_available` gauge absent — operator
    cannot detect imminent rate-limit storms.** During an anomalous traffic
    spike (forecast says <3 RPS peak; suppose a CI bug pushes 20 RPS), the
    bucket starts rejecting at 5 RPS. The on-call sees
    `proxy_requests_total{outcome=rate_limited}` going up, but has no way
    to tell whether the bucket is at 0 tokens (sustained overload) or
    intermittently dipping (transient burst). The runbook step "wait for
    inbound to subside" needs a signal for "are we at the cap right now?".
    The ADR's Open question flags this; the answer should be a gauge.
  - **Scenario 2: NTP step on container host distorts `Date.now()`-based
    callers but not the bucket — observability mismatch.** Proxy uses
    `hrtime`, defending against NTP step (good). But ADR-005's pino log
    timestamp is `pino.stdTimeFunctions.isoTime`, which is `Date.now()`-based.
    A 5-second NTP backwards step at 3am makes the per-request log line
    have a `time` field 5 s before the previous line, and the
    `latency_ms` field (computed from `requestStart` BigInt) is correct.
    On-call running `journalctl -S timestamp` sees out-of-order log lines
    and assumes the proxy is misbehaving; the dashboard `latency_ms` panel
    is correct. This is not the bucket's fault, but the cross-ADR
    inconsistency (bucket uses hrtime, log timestamps use Date) is exposed
    by the bucket choice.
- **Operational problems**:
  - No `proxy_ratelimit_tokens_available` gauge means the on-call sees the
    symptom (`rate_limited` count rising) but cannot confirm the bucket
    is at zero vs flapping. ADR-004 explicitly names this as deferred to
    a future iteration; for production triage, this is a gap.
  - No alert threshold defined anywhere for `proxy_requests_total{outcome=rate_limited}`. NFR-CAP-2 says expected peak is 3 RPS inbound; rate_limited
    should be 0 in steady state. A non-zero rate is itself an anomaly. No
    ADR defines this alert.
  - The 1-second `Retry-After` floor over-advises by up to 4×, and the
    spec acknowledges this. Callers using the SDK will back off by a full
    second when 200 ms would suffice, halving effective throughput. The
    ADR is faithful to FR-7 here but the trade-off should be documented in
    a caller-facing note.
- **Disagree-flag (MANDATORY)**:
  - `I considered the following objections and rejected them because:
    (1) "the bucket should be Redis-backed for multi-instance correctness"
    — rejected because NFR-CAP-1 explicitly calls out single-instance,
    Redis would add a hard dependency NFR-DEP-1 does not name, and the
    deployment topology (NFR-DEP-2: single Docker container) makes
    multi-instance a deploy-procedure violation, not a scaling option;
    (2) "fractional-token refill is overkill, integer tokens at 200 ms
    boundaries are simpler" — rejected because the integer-quantised
    approach was Alternative C in the ADR, has documented event-loop-lag
    drift, and the fractional approach is not actually more complex once
    written; the math in the ADR's step 3 is three lines.`

### ADR-005: pino + prom-client on a separate metrics port, with redaction and AsyncLocalStorage correlation

- **Verdict**: challenge
- **Arguments**:
  - **pino's path-based redact is admitted-fragile and the mitigation (a CI
    grep test) is not in any ADR's enforcement loop.** The Negative section
    says "a future code path that puts the API key in a *different* field
    (e.g. `metadata.token`) silently evades redaction... we will add a *grep
    test* in CI that scans test-environment log output for the literal value
    of a fake test key and fails the build if it appears". This grep test
    is a derived control the ADR author named themselves; it lives nowhere
    in the spec, nowhere in the build pipeline ADR-007 describes, and there
    is no test fixture defined. NFR-SEC-1 calls the secret-in-logs prohibition
    "the highest-cost defect we could ship". The mitigation for that
    highest-cost defect is a CI test that the deploy pipeline does not
    enforce. Trade-off axis hit: `correctness` and `operability` are pushed
    to a non-existent CI control.
  - **`proxy_upstream_status_total{status}` cardinality is not actually
    bounded.** The ADR says "we accept the unbounded-in-theory cardinality
    because the upstream domain is controlled (DeepSeek alone, FR-2)". This
    is wrong: a misbehaving caller, a CDN in front of DeepSeek, or a hijacked
    DNS could return arbitrary status codes (including non-numeric strings
    if the parser is not strict). prom-client's counter creates a label series
    on first observation; an attacker who can reach the proxy (NFR-SEC-1
    perimeter trust) can create unbounded series by triggering odd upstream
    statuses (or, if the upstream HTTP parser ever surfaces a status string
    instead of an integer, the label could be `"<malformed>"`). Cardinality
    blow-up is a Prometheus DoS, not a proxy DoS. ADR-005 should pin the
    label to a known allow-list (`"200","201","400","401","403","404","429","500","502","503","504","other"`).
  - **AsyncLocalStorage correctness depends on Fastify never escaping the
    request context, but the orchestrator (ADR-003) does setTimeout-based
    sleeps that span async boundaries.** AsyncLocalStorage propagates through
    `async/await` and `setTimeout` in modern Node, but explicit
    `setTimeout(controller.abort, ...)` callbacks scheduled from outside the
    request handler can lose context if not wired via the `als.run` wrapper.
    The ADR does not specify how the wall-time abort and retry-backoff sleep
    are wrapped; if they run outside ALS context, log lines emitted from
    the timeout callback (e.g. `log.warn('wall-time guard fired')`) lose
    `request_id`. This is an integration risk between ADR-002, ADR-003, and
    ADR-005; no ADR owns it.
- **3am production failure scenarios**:
  - **Scenario 1: secret leaks through a code path the redact list missed.**
    A new developer adds error-mapping code: `log.error({ err, req: { headers:
    request.headers } })` — the redact path `req.headers.authorization`
    matches and redacts. Two months later, they refactor to
    `log.error({ err, ctx: { headers: request.headers } })`. The redact
    paths are `req.headers.*` and `*.headers.authorization`; the second
    matches, the first does not. They later add a wrapper that puts the
    headers under `metadata.upstreamHeaders.Authorization`. Now neither
    pattern matches; the next 5xx logs the bearer token to stdout.
    Splunk indexes it. At 3am someone notices when DeepSeek's anomaly
    detection alerts on traffic from an unknown source IP using the same key.
    Root cause: the redact paths are not exhaustive and there is no
    behavioural test. The "grep test in CI" the ADR mentions does not exist
    in any ADR or template.
  - **Scenario 2: cardinality blowup from an unhandled upstream status.**
    DeepSeek's CDN returns HTTP 522 (Cloudflare connection timed out) under
    a brief outage. The proxy increments
    `proxy_upstream_status_total{status="522"}`. Then 525, 526, 530.
    Each new status is a new label series. Prometheus storage grows;
    federation cost goes up. Not catastrophic alone, but a recurring CDN
    fault that bounces between 50+ status codes (rare but documented) creates
    persistent cardinality. The metric was meant to be bounded by HTTP's
    universe; it is bounded by what *ever* hits the proxy, which is
    larger.
- **Operational problems**:
  - The `proxy_up` gauge transition (1 → 0 on SIGTERM) is the only signal
    distinguishing "drain in progress" from "process crashed". If the gauge
    flips and `/metrics` becomes unscrapeable 100 ms later (process exit),
    Prometheus stale-marker semantics make the gauge appear stuck at 1
    until the scrape staleness window (5 min default). The intended signal
    is invisible during fast shutdowns. ADR-006 keeps metrics up during
    drain, which mitigates — but the ADR-005 alerting story does not name
    a "proxy_up == 0 for > 35 s OR no scrape for > 30 s" composite alert.
  - No alert thresholds are defined for any metric. NFR-OBS-1 mandates the
    metrics; ADR-005 names them but specifies no alert. On-call sees the
    metrics on a dashboard; nothing pages.
  - `proxy_request_duration_ms` histogram buckets do not include a bucket
    between 12000 and 30000. A request landing at 18 s (one attempt + retry
    + backoff under variable upstream latency) lands in the 30000 bucket,
    indistinguishable from a wall-time-aborted 30 s request. p99 will read
    "30 s" for both, hiding the difference between "almost timed out" and
    "did time out".
- **Disagree-flag (MANDATORY)**:
  - `I disagree with: leaving proxy_upstream_status_total{status} cardinality
    unbounded "because the upstream domain is controlled". The upstream
    domain is one DNS name — the response status is not. A CDN, an edge
    LB, or a fault-injection misconfig can produce arbitrary 5xx values
    (522, 524, 525, 530), and the proxy will create a new series for each.
    The right shape is to map all upstream statuses through a fixed bucket
    (e.g. "2xx","4xx","429","500","502","503","504","other") at the metric
    layer, while keeping the per-request log's upstream_status field as the
    raw integer. NFR-OBS-1's intent (low-cardinality counters) is preserved
    and the per-request log keeps full fidelity for incident triage.`

### ADR-006: 30-second graceful drain with proxy_up flip and Connection: close

- **Verdict**: challenge
- **Arguments**:
  - **The `stop_grace_period` requirement is "deployment-side correctness, not
    enforced by code" and the ADR admits this.** The Negative section says
    "an operator who ignores it ships a silently-non-compliant deploy". Under
    the Docker default `stop_grace_period: 10s`, SIGKILL fires at 10 s; any
    in-flight request that has already started its NFR-LAT-1 30-s budget
    sees the kernel TCP-RST its caller. The proxy has no way to detect this
    misconfiguration at boot — `stop_grace_period` is a Docker-side property,
    not visible to the container process. This is a single-failure-mode where
    the spec's contract (drain ≥ 30 s) is silently violated by the absence of
    one YAML key. The proxy could at minimum log a WARN at boot if it
    detects it is running under PID 1 in Docker without a way to verify
    grace-period — or document this as the very first runbook check. Trade-off
    axis: `operability` is fully delegated to documentation.
  - **The drain timer's forced socket destruction at 30 s collides with the
    edge case the ADR itself names.** "An inbound request that arrived 0.5 s
    before SIGTERM has 29.5 s of remaining wall-time; the drain timer fires
    before its wall-time, and the proxy has destroyed the socket. Caller sees
    TCP RST." The ADR accepts this. But under combined load — say SIGTERM
    arrives during a retry-after-backoff sleep — the timer is racing the
    request lifecycle in a way that produces non-deterministic outcomes from
    the caller's perspective. NFR-OBS-1's per-request log line for the
    forced-destroyed request will be partial (the request never reached
    `onResponse`); the closing log is emitted from the abort path or not at
    all. On-call running incident reconstruction sees orphaned `request_id`s
    in the X-Request-Id of upstream logs but no matching proxy log line.
  - **The `proxy_up == 0` ↔ `/healthz` 503 coupling makes the deploy verify
    step ambiguous.** ADR-006 says: "GET /healthz → `{"status": "ok"}` while
    `proxy_up == 1`, 503 while drain is in progress". ADR-007's deploy step
    4 says "verify by hitting `/metrics` and confirming `proxy_up == 1`"
    — but ADR-006 also keeps the metrics listener up during drain. So between
    `docker compose stop` (start of drain) and `process.exit(0)` (end of
    drain), `/metrics` returns `proxy_up == 0`. If an operator runs the
    verify step too early after `docker compose up -d` (or, more realistically,
    if the new container starts and the metrics listener binds before
    initialisation completes), they see `proxy_up == 0` for the *new*
    container and assume drain is still in progress for the old one. There
    is no version label discrimination on the gauge — `proxy_up` is the
    same metric across image versions. Combined with `proxy_build_info`
    being a separate metric, the operator must do a join across two metrics
    in the verify step that the runbook does not specify.
- **3am production failure scenarios**:
  - **Scenario 1: Operator deploys with default `stop_grace_period: 10s`.**
    A new operator (or a CI runner that templates compose from somewhere
    else) ships a deploy without the 30-s override. SIGTERM at T=0;
    `apiServer.close()` returns when its callback fires (idle pool); the
    drain log is emitted. At T=10 s, Docker sends SIGKILL. Any in-flight
    upstream request receiving its response between T=10 s and T=30 s is
    truncated mid-stream. On-call sees: `proxy_requests_total{outcome=transport_error}` spike on every deploy; the per-request log lines are
    incomplete (process killed before `onResponse`). The connection between
    "transport_error spike" and "deploy" is inferred from timestamps,
    not metrics. There is no `proxy_drain_aborted_total` counter or boot-time
    self-check.
  - **Scenario 2: Drain progress log floods at 5-second cadence with no
    structured signal.** ADR-006 says "we can log the drain progress (number
    of sockets remaining, countdown) at INFO every 5 s during drain". This
    violates NFR-OBS-1's "exactly one log line per inbound caller request"
    rule (a side effect, not a request log, but it pollutes the same stdout
    stream). On-call greps for `request_id` and gets noise. Worse, the log
    line is at INFO level — production log aggregation may rate-limit it
    and lose the actual drain timeline. This is a small operability
    regression from a derived control the ADR names but the spec does not.
- **Operational problems**:
  - No boot-time self-check for `stop_grace_period`. The proxy could PID-1-detect
    Docker and emit a WARN if it cannot verify the grace period (e.g. by
    checking environment for known supervisor markers), but ADR-006 does not.
  - No metric `proxy_drain_aborted_total` for "in-flight requests killed by
    the drain timer". A spike is currently invisible until logs are mined.
  - The `Connection: close` header on 503-during-drain only fires on
    new connections that slip in via the preHandler hook race. The ADR does
    not explicitly mandate `Connection: close` on the *normal* responses
    during drain — once `apiServer.close()` is called, in-flight responses
    should also tell the caller "this connection is going away" so the
    caller does not attempt keep-alive on a dying socket.
  - SIGINT handling is in Open questions, not pinned. A dev-env SIGINT
    behaviour mismatch can confuse operators investigating production
    incidents using local-repro scripts.
- **Disagree-flag (MANDATORY)**:
  - `I disagree with: relying solely on documentation to enforce the
    stop_grace_period: 30s contract. The proxy can do better: at boot, it
    can detect PID-1 + cgroup environment (a strong signal of running under
    a Docker supervisor) and emit a WARN-level log with a recognisable
    string ("stop_grace_period_unverified") that operators can search for
    in their deploy logs and that CI can fail builds on. This converts a
    silent procedural violation into a loud signal. Yes, this is a derived
    control not in the spec; so is the drain progress log line the ADR
    happily added on operability grounds.`

### ADR-007: Hand-rolled env-var validation, distroless Node 22 image, single-instance via host-port mapping

- **Verdict**: challenge
- **Arguments**:
  - **Single-instance enforcement is a *deployment-procedure* invariant with no
    code-level fallback.** ADR-007 names the runbook step ("`docker compose
    stop && docker compose wait` then `docker compose up -d`") as the primary
    mechanism. The host-port mapping + FR-9 bind-or-die is the secondary.
    But on a host *without* the host-port mapping (e.g. operator deploys
    with `network_mode: host` for performance, or the compose file is edited
    to remove the port mapping), the only enforcement is procedure. The
    ADR rejects file-lock-based enforcement because of orphan-lock 3am risk
    — fair — but rejects in-process leader election entirely without
    discussing a lighter-weight option such as `bind() + listen()` on the
    actual port being a sufficient lock (which it already is, but only on
    the configured `PORT` and only if host-port mapping is in place). The
    NFR-CAP-1 violation from running 2 instances is silent (each process
    has its own bucket) and produces a 2× DeepSeek bill. There is no metric
    or alert for "two instances are running"; if the operator shipped both
    behind a single LB, NFR-OBS-1 metrics from each instance flow to
    Prometheus with the *same* `service` label, and only the
    `proxy_build_info{git_sha}` cardinality (or pod IP labels added by
    Prometheus) would distinguish them — and that depends on the scrape
    config the ADR does not own.
  - **Distroless Node 22 + `--max-old-space-size=384` is a sane default but
    the resource limits are explicitly *recommended*, not mandated.** The
    spec says "Container resource limits and Node heap settings: explicit
    limits are NOT mandated by this spec — left to the operator". ADR-007's
    compose template includes them but offers no boot-time check that they
    are present. An operator who omits `mem_limit` runs with the host's
    cgroup default (often unlimited), which makes OOM detection a host-level
    problem. The ADR claims "OOM-kill is now a known-impossible failure for
    the forecast load"; this is true *when the operator follows the
    template*. It is not enforced.
  - **`BUILD_VERSION` and `BUILD_GIT_SHA` are runtime env-vars rather than
    build-time embedded.** ADR-007's Open question flags this; my reading is
    runtime is the wrong choice for `proxy_build_info`. The whole purpose
    of `proxy_build_info` is to detect "is the deployed image the version
    I expected?" — if the version label comes from the deploy environment
    rather than the binary, an operator who copy-pastes a stale env file
    can ship a new image with the old version label. The metric becomes
    useless for the alert it was designed to support ("alert if proxy_build_info{version=old} for > N minutes after deploy"). Build-time
    embedding (via Dockerfile `ARG VERSION` + `ENV BUILD_VERSION=$VERSION`)
    is the cheap fix; the ADR chose simplicity over verifiability.
- **3am production failure scenarios**:
  - **Scenario 1: deploy script regression triggers two-instance run.**
    A CI deploy job is rewritten to use `docker compose up -d --force-recreate` (which does in fact stop the old container, but in a different order
    than the ADR's `stop && wait && up`). Under load, there is a 3-second
    window where both containers are running and bound (depending on the
    Compose version's recreate behaviour). FR-9 bind-or-die fires for the
    second container's API port (good) — but the metrics port (`9090`) was
    started first in the boot sequence and got past bind. The new container
    crashes on API port bind, but the metrics port from the dying old
    container is also gone. Now `/metrics` is 503 for ~3 s during deploy.
    Prometheus marks scrape stale; on-call's "deploy went bad" alert fires
    (if anyone wired it). The ADR's procedure said "do not use --force-recreate" but a CI engineer who didn't read the runbook used it. Result:
    a transient outage (acceptable per NFR-AVL-1) plus a false-positive
    alert that a tired on-call must triage. There is no metric for
    "instance start" / "instance stop" the dashboard can correlate with.
  - **Scenario 2: `NODE_TLS_REJECT_UNAUTHORIZED=0` from a sibling service's
    env leaks into the proxy.** A shared `.env` file used across multiple
    services has `NODE_TLS_REJECT_UNAUTHORIZED=0` for a local-dev mock
    service. Operator copies it to staging, then to prod. Proxy boots,
    config validator fires, `process.exit(1)`. Container restart loop. On
    the first restart attempt, the operator sees: `docker logs deepseek-client` shows the ERROR "NODE_TLS_REJECT_UNAUTHORIZED must not be 0".
    Restart policy `unless-stopped` fights the container's own exit. CPU
    spins on the restart loop for hours until someone notices. ADR-007's
    refuse-to-start is correct (NFR-SEC-1 protected), but a fast restart
    loop is itself a DoS on the host, the registry, and the alerting noise.
    There is no `RestartPolicy: on-failure:5` cap.
- **Operational problems**:
  - No boot-time self-test that emits a structured "boot OK" log line with
    all the validated config values (redacted). Operators have no machine-readable confirmation that the right `DEEPSEEK_BASE_URL`, the right
    `PORT`, and the right `BUILD_VERSION` were loaded.
  - No restart-loop protection. `unless-stopped` retries forever; a config
    error or transient failure on boot causes the host to spin.
  - The deploy verify step (`curl /metrics | grep '^proxy_up 1'`) does not
    differentiate the new image from the old. If `proxy_build_info` is
    runtime-env-driven, the operator cannot trust that the running image
    is actually the new one.
  - The 30-s `stop_grace_period` is documented in the compose template but
    not asserted at boot (ADR-006 disagree-flag).
- **Disagree-flag (MANDATORY)**:
  - `I disagree with: passing BUILD_VERSION and BUILD_GIT_SHA via runtime
    env-vars rather than build-time-embedded ARG/ENV in the Dockerfile.
    The metric proxy_build_info is the deploy-verification anchor; if the
    label comes from the operator's environment rather than the binary,
    an operator who reuses a stale .env will ship a new image labelled
    with the old version, defeating the metric's whole purpose. Fix:
    bake VERSION and GIT_SHA into the image at build time via Docker ARG
    + ENV. Allow runtime override only for explicit dev/test scenarios,
    and guard the override behind a separate feature flag so it cannot
    happen by accident in prod.`

## Cross-cutting issues

> Issues that span multiple ADRs or aren't owned by any single ADR.

- **No alert thresholds defined anywhere.** NFR-OBS-1 mandates 5 metrics;
  ADR-005 instantiates them. No ADR defines: (a) `proxy_requests_total{outcome="gateway_timeout"}` rate threshold (e.g. ">0.1/s for 5min" → page),
  (b) `proxy_requests_total{outcome="rate_limited"}` rate threshold (any
  sustained non-zero is anomalous per NFR-CAP-2), (c) `proxy_upstream_status_total{status=~"5.."}` rate threshold, (d) `proxy_up == 0` for >35 s
  alert, (e) `proxy_request_duration_ms` p99 > 25000 alert. The on-call
  has dashboards but no pages. This is the single largest operability gap.

- **Pool saturation is unobservable.** ADR-002 chose `connections: 8` and
  acknowledged the working-set could be 36 under p99-latency loads. There
  is no `proxy_upstream_pool_pending`, `proxy_upstream_pool_active`, or
  `proxy_upstream_pool_idle` gauge. On-call cannot distinguish "pool
  starvation" from "DeepSeek slow" without log-mining individual `latency_ms`
  vs `upstream_latency_ms` deltas. Add to NFR-OBS-1.

- **Retry diagnosis is hidden.** ADR-003 produces three distinct "retry not
  attempted" outcomes (wall-time exhausted, Retry-After exceeds budget,
  initial attempt succeeded) all of which collapse to `retry_count=0` in
  the per-request log. There is no `proxy_retries_skipped_total{reason}`
  counter. Operators cannot tune the retry policy without instrumentation
  the ADRs do not include.

- **AsyncLocalStorage context-loss between ADR-002 (abort callbacks),
  ADR-003 (setTimeout-based backoff), and ADR-005 (logging).** Each ADR
  assumes ALS context is preserved when its callbacks fire. No ADR specifies
  the wrapping pattern (`als.run(ctx, () => ...)` vs `als.bind(...)`).
  A misuse means timeout-fired log lines have `request_id: undefined` and
  the on-call's grep-for-id playbook breaks. Owner: ADR-005, but it cannot
  unilaterally specify ADR-002/003's call patterns.

- **Cardinality risk on `proxy_upstream_status_total{status}` is not
  bounded by an allow-list.** ADR-005's "the upstream domain is controlled"
  reasoning is wrong; the upstream *domain* is one DNS name, but the
  *response status* is whatever DeepSeek's CDN/edge returns. Fix at
  metric-emission site, keep raw integer in the per-request log.

- **Failure isolation: the proxy is a single point of failure for the
  caller's LLM access.** NFR-AVL-1 explicitly accepts this. The blast radius
  is named ("a single instance going down means downtime"), but there is
  no mention of what the *caller* should do — caller-side fallback
  documentation is out of scope, but at minimum the proxy's own
  caller-facing error contract (FR-7's `Retry-After`, FR-12's strict
  rejections) should be summarised in a "caller integration notes" section
  somewhere. ADR-001 owns the surface; it does not own the caller-facing
  guidance. Operators must rediscover this every incident.

- **Deployment topology: stop-then-start is procedural, single-instance
  enforcement is partial.** Across ADR-006 and ADR-007, the deploy
  contract has 4+ load-bearing pieces (stop_grace_period: 30s, host-port
  mapping, mandatory stop+wait+up sequence, refusing rolling deploys) and
  no single piece of code or alert that fails when one is violated. NFR-DEP-2
  is upheld by reading-the-runbook. The ADR-006 disagree-flag's suggestion
  (boot-time WARN if grace period unverified) is one mitigation; another
  is a `proxy_instance_id` gauge with a startup-random label so two-instance
  runs become visible in Prometheus as duplicate series. Neither exists.

- **Rollback story is absent.** NFR-AVL-1 names "process restart on crash"
  but no ADR defines the rollback procedure if a deploy ships a broken
  image. ADR-007's runbook ends at step 4 (verify `proxy_up == 1`); there
  is no step 5 ("if proxy_up != 1 within 60 s, run `docker compose down &&
  docker tag deepseek-client:previous deepseek-client:current && docker
  compose up -d`"). Combined with the absence of a restart-loop cap, a
  bad image can spin forever before someone manually rolls back at 3am.

- **No metric for upstream `Authorization`-header presence on the wire.**
  NFR-SEC-1 forbids logging the key but says nothing about verifying that
  the proxy *did* set the header on every upstream attempt. A missing
  Authorization header would surface as upstream 401 from DeepSeek; the
  proxy would forward it as `client_error`. There is no boot-time test
  or per-request invariant check that the header is set. A regression here
  (e.g. an upgrade that breaks the undici header-injection path) presents
  as a 100% upstream-401 rate with no clear root cause.

## Final verdict

- **Verdict**: iterate
- **Required follow-ups before next stage**:
  1. **Revise ADR-001** to either replace the FR-4 substring stream-detection
     with a top-level-key streaming JSON tokenizer or scope the substring
     scan to brace-depth-1 keys only; add an integration test that POSTs a
     prompt body containing the literal text `"stream":true` inside a string
     value and asserts HTTP 200 (forwarded), not 400.
  2. **Revise ADR-002** to (a) make `connections` configurable via env
     `POOL_CONNECTIONS` with a default of 8, (b) add metrics
     `proxy_upstream_pool_pending`, `proxy_upstream_pool_active`,
     `proxy_upstream_pool_idle` (gauges) and document them in NFR-OBS-1
     amendments, (c) document a runbook entry "if pool_pending > 0
     sustained, raise POOL_CONNECTIONS".
  3. **Revise ADR-003** to (a) replace the `Retry-After: 0`
     absent/malformed default with the same FR-6 jittered backoff used for
     Class A (or a deterministically-jittered alternative such as
     `200 + crypto.randomInt(0, 100)` ms), (b) add a counter
     `proxy_retries_skipped_total{reason}` with reasons
     `wall_time_exhausted`, `retry_after_exceeds_budget`, `not_eligible`.
  4. **Revise ADR-005** to (a) bound `proxy_upstream_status_total{status}`
     to an allow-list (`"2xx","4xx","429","500","502","503","504","other"`)
     while keeping the raw integer in the per-request log's `upstream_status`
     field, (b) define alert thresholds for every NFR-OBS-1 metric (page
     conditions and warn conditions, with concrete rate/duration thresholds),
     (c) add a `proxy_request_duration_ms` histogram bucket between 12000
     and 30000 (e.g. add 15000, 20000, 25000) so "almost timed out" is
     distinguishable from "timed out", (d) define and document the CI
     grep-test that asserts no test-fake-API-key value appears in any log
     output.
  5. **Revise ADR-006** to (a) add a boot-time check that emits a WARN-level
     log line with a known-greppable string if running under PID 1 in
     Docker without a verifiable `stop_grace_period >= 30s`, (b) add a
     counter `proxy_drain_aborted_total` for in-flight requests killed by
     the drain timer, (c) explicitly mandate `Connection: close` on all
     responses emitted after `apiServer.close()` is called (not just on the
     503-during-drain race-window response), (d) pin SIGINT handling
     (mirror SIGTERM) rather than leaving it as an Open question.
  6. **Revise ADR-007** to (a) bake `BUILD_VERSION` and `BUILD_GIT_SHA`
     into the image at build time via Docker ARG/ENV; runtime override
     only behind an explicit feature flag, (b) add a restart-loop cap to
     the compose template (`restart: on-failure:5` or equivalent) plus a
     runbook step for what to do if the cap is hit, (c) add a step 5 to
     the deploy runbook for rollback ("if proxy_up != 1 within 60 s, roll
     back to the previous image"), (d) emit a structured "boot OK" log
     line including all redacted config values for operator confirmation.
  7. **Add an ADR-008 (Alerts and runbook)** that names every page-able and
     warn-able metric threshold (referencing the alerts requested under
     items 4 and 5 above), defines the on-call runbook for each alert,
     and pins the rollback story. The current set of ADRs ships
     instrumentation without alert semantics; this is the single largest
     operability gap.
