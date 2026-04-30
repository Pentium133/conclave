# Spec review: deepseek-client

## Frame

> Imagine it is 3am, the on-call engineer is paged because this system is on fire in production.
> What in the spec, as written, made the failure possible? What is missing, ambiguous, or
> contradictory that will hurt the engineer right now?
>
> The reviewer's job is to find as many such failure modes as possible BEFORE we approve the spec.

## Objections

### Objection 1

- **Severity**: block
- **Area**: contradiction
- **Scenario**: 03:14, alerts fire: "p99 caller latency 31s, callers report 504s during a brief DeepSeek brown-out". The incident timeline shows the initial attempt to DeepSeek took 14.0 s and timed out before first byte (transport error → eligible for retry per FR-5). The proxy slept ~0.6 s and started the retry. The retry itself took 13.9 s and returned 200 OK. Total wall-time: 14.0 + 0.6 + 13.9 = 28.5 s — under the 30 s NFR-LAT-1 budget — yet many requests in the same window saw the *retry's* upstream call complete after 14.0 s+ (TLS variance, jittered backoff at the upper end), tripping the wall-time guard at exactly the moment the success bytes were arriving. Per NFR-LAT-2 the retry attempt itself can consume up to 14 s (and the spec's own arithmetic claims 1.4 s of headroom — measured slack is below typical Node event-loop GC pause + TLS handshake jitter). The on-call sees a thundering herd of `gateway_timeout` outcomes that *would* have succeeded, billed twice (DeepSeek processed the upstream attempts and charged for both), and they cannot tell from the spec whether to widen the wall-time, narrow the per-attempt timeout, or kill the retry. The spec asserts 28.6 s + 1.4 s headroom is enough but does not specify what happens when the timing race is lost: the proxy's mid-flight upstream call MUST be aborted and the upstream socket closed, otherwise the proxy continues to consume DeepSeek bytes after returning 504 to the caller (burning quota and money on a request the caller already considers failed).
- **What to fix**: Add an FR or NFR that specifies abort propagation: when NFR-LAT-1 wall-time expires, the proxy MUST cancel the in-flight upstream HTTP request (close the socket / abort the fetch controller) before returning 504 to the caller, and MUST NOT consume any further upstream response bytes. Also nail down the per-attempt retry total: either lower NFR-LAT-2 retry-attempt total to ≤12 s OR widen NFR-LAT-1 to 32 s. The current "1.4 s headroom" is below realistic proxy overhead (TLS resume, GC, queue scheduler) and the spec must explicitly state which budget gives.
- **Refs**: NFR-LAT-1, NFR-LAT-2, FR-6

### Objection 2

- **Severity**: block
- **Area**: missing
- **Scenario**: 03:42, finance dashboards show DeepSeek bill spiked 4× overnight and a `transport_error`-rate alert is silent. Investigation: an internal CI job (perimeter-trusted, no caller auth per NFR-SEC-1) was misconfigured to run a 5000-iteration prompt-eval against the proxy in a tight loop. There is no inbound rate limit (NFR-CAP-1 is *outbound* only), no caller identity, no per-caller quota, and no body-size cap. Because the inbound forecast (NFR-CAP-2) is 1–3 RPS and the outbound bucket is 5 RPS, every single request the rogue CI sent went to DeepSeek and was billed. The on-call has no log field identifying *which* internal service did this (no `caller_id`, no source IP in the logs per NFR-OBS-1), no way to selectively block them without a redeploy, and no body-size cap to stop a caller from sending 100 MB prompts. The team's monthly budget evaporates by morning.
- **What to fix**: Add three things. (1) An NFR-SEC-2 explicitly stating the threat model assumption that *anyone reachable on the perimeter can drain the upstream key's quota* and either accept this risk in writing OR mandate a minimum control (e.g., a static shared header token, a per-source-IP token bucket, or a max-requests-per-source-IP-per-day cap). (2) An FR for inbound request body size limit (e.g., reject `Content-Length > 256 KB` with HTTP 413). (3) An NFR-OBS amendment requiring the access log to record source IP and a coarse caller fingerprint (e.g., `User-Agent`) — these are not PII like prompt bodies and are needed for incident attribution.
- **Refs**: NFR-SEC-1, NFR-CAP-1, NFR-OBS-1, missing — no ID yet

### Objection 3

- **Severity**: major
- **Area**: contradiction
- **Scenario**: 02:55, deploy of v1.4.0 triggers a rolling restart. Operator runs `docker compose up -d` which briefly runs the new container alongside the old one (default behaviour during image pull + start). Both containers share the same `DEEPSEEK_API_KEY` and each runs its own process-local 5 RPS token bucket — total outbound 10 RPS for ~30 s. DeepSeek's account-level rate limit (which the spec assumes 5 RPS respects) trips and DeepSeek starts returning 429s to *both* proxy instances. Per FR-5 these 429s are forwarded as-is and not retried, so callers see a flood of 429s during every deploy. NFR-DEP-2 says "single-instance only" and the rationale text explicitly acknowledges N replicas would multiply the rate, but the spec provides zero enforcement: no startup leader-election, no advisory file lock, no health-check that fails-fast on a second instance, and no documented deploy procedure that guarantees the old container is fully stopped before the new one starts. "Single-instance only" is a wish, not a constraint.
- **What to fix**: Either (a) add an FR mandating a startup mutex (e.g., bind a fixed local UDP/TCP port whose presence proves an instance is running, exit if already bound) AND a documented `stop-then-start` deploy procedure that forbids overlap, OR (b) lower NFR-CAP-1's outbound rate to a fraction of DeepSeek's account budget (e.g., 2 RPS) so that even 2× momentary overlap stays under the upstream cap, OR (c) explicitly accept the deploy-window double-rate as a known risk in NFR-AVL-1 with the on-call expectation written down.
- **Refs**: NFR-DEP-2, NFR-CAP-1, NFR-AVL-1

### Objection 4

- **Severity**: major
- **Area**: contradiction
- **Scenario**: 11:20 (not 3am, but the consequence wakes someone at 3am later), an operator does a routine `docker compose pull && up -d`. The new container starts, the old one receives SIGTERM. Per NFR-AVL-1 the drain window is ~5 s. But NFR-LAT-1 says the wall-time per request is up to 30 s and NFR-LAT-2 says a single attempt can take 14 s. The drain window is therefore 6× shorter than a typical in-flight request lifetime. Every in-flight request mid-deploy is killed, callers see TCP RST or empty response, retry on their side (the proxy refuses retries on the upstream side per FR-5 but says nothing about *caller-initiated* retries — the caller's TCP failure may have happened after DeepSeek already processed the call and billed for it). At 3am later, an SRE investigating a `caller_timeout` alert finds the cause was the lunchtime deploy and there is no spec-mandated way to do safe deploys.
- **What to fix**: Reconcile the drain window with the request lifetime. Either widen the drain window to ≥ NFR-LAT-1 (30 s) so in-flight requests can complete, OR explicitly state that deploys WILL kill in-flight requests and document the operator runbook step ("drain caller traffic upstream of the proxy before SIGTERM"). Add a sentence specifying what HTTP status / connection behaviour the proxy presents to callers during the drain window for *new* requests (503? immediate connection refusal? "Connection: close" header?).
- **Refs**: NFR-AVL-1, NFR-LAT-1, NFR-LAT-2

### Objection 5

- **Severity**: major
- **Area**: edge
- **Scenario**: 04:10, DeepSeek's edge load balancer is having a partial outage and emits HTTP 502 for ~30% of requests for ~10 minutes. Per FR-5, *any* HTTP response — including 502, 503, 504 — is forwarded as-is and never retried. Callers see a 30% error rate. The `outcome` metric label `upstream_5xx` ticks up. The on-call's Prometheus dashboard shows `outcome="upstream_5xx"` rising but not split by upstream status code, so they cannot tell whether DeepSeek is returning 500 (genuine server error, retry won't help), 502 (edge LB problem, retry on a different connection likely succeeds), 503 (overload, backoff helps), or 504 (upstream-side timeout, retry semantics unclear). Worse, the rationale in FR-5 ("chat completions are non-idempotent → don't retry HTTP responses") *over-applies* to 502: a 502 from the edge LB means the request very likely never reached the model, so the non-idempotency argument doesn't bite there. The spec's blanket "no retry on any HTTP response" trades a specific risk (double billing on 5xx-after-model-ran) for a different one (gratuitous error rate during edge problems).
- **What to fix**: Either (a) carve out a narrow exception in FR-5 for upstream 502/503 with an explicit "Retry-After"-aware backoff and a documented argument why double-billing risk is bounded for these codes, OR (b) explicitly reaffirm "we accept higher error rate during DeepSeek edge problems in exchange for zero double-billing" with a concrete acceptance criterion. Either way, NFR-OBS-1's `outcome` enum must include the upstream HTTP status code as a label or a separate counter (`upstream_status_code`) so on-call can distinguish 500 vs 502 vs 503 vs 504 without reading individual log lines.
- **Refs**: FR-5, FR-6, NFR-OBS-1

### Objection 6

- **Severity**: major
- **Area**: missing
- **Scenario**: 03:30, callers report 30% of requests "hanging then failing"; their client TCP times out at 60 s. Investigation: a caller hit the proxy and got a TCP RST partway through reading the response. They retry on their side. The proxy has no idempotency-key support, so DeepSeek now processes the same prompt twice (charged twice) and the caller may receive two divergent completions; if their app dedupes on response only, they may even consume the wrong one. The spec is silent on idempotency keys (no `Idempotency-Key` header, no client request id passthrough, no echo of a caller-provided correlation id). NFR-OBS-1 has a proxy-assigned `request_id` for *logs*, but it isn't returned to the caller in a response header, so callers cannot correlate proxy-side log lines to their client-side errors when reporting an incident.
- **What to fix**: Add an FR specifying response header `X-Request-Id` (or similar) returned to the caller that matches the log `request_id`. Add an explicit out-of-scope statement OR an FR for handling caller-supplied `Idempotency-Key` / `X-Request-Id` headers (echo them, log them, optionally dedupe within a short window). At minimum, the spec must explicitly acknowledge "if a caller's TCP fails after the proxy has flushed bytes upstream, the caller has no safe way to retry without risking double billing — callers must treat this as a known failure mode."
- **Refs**: NFR-OBS-1, missing — no ID yet

### Objection 7

- **Severity**: major
- **Area**: NFR
- **Scenario**: 02:20, DeepSeek upstream returns HTTP 429 with `Retry-After: 60`. Per FR-5, this is forwarded as-is to the caller. Per FR-7, when the *local* outbound bucket is exhausted, the proxy returns 429 with a `Retry-After` derived from the local bucket. But the spec is silent about which `Retry-After` the caller sees in the *upstream-429-forwarded* case: does the proxy forward DeepSeek's `Retry-After` (which reflects DeepSeek's account-level cooldown — the proxy has no insight into it and forwarding it as-is may mislead callers because DeepSeek's value applies to the proxy's API key, not the caller's identity), or does it overwrite it with its own bucket's value? Worse: in the *local* 429 case (FR-7), the spec says `Retry-After` is rounded up to whole seconds with minimum 1 — but the bucket refills at 5 tokens/sec (200 ms per token), so the minimum-1-second floor makes the proxy *advise callers to wait 5× longer than necessary*, leading to caller-side starvation under burst conditions.
- **What to fix**: Specify in FR-7 (and adjacent text near FR-5) which `Retry-After` value is presented to the caller in each scenario: (a) local outbound 429 → use the bucket's actual ms-precision wait, allow sub-second values via `Retry-After` formatted as integer seconds rounded UP only if HTTP-spec compliance is required (and document the over-advise as a known minor cost), OR allow the HTTP-date form, OR add a finer-grained header like `X-RateLimit-Reset-Ms`. (b) upstream 429 forwarded → state explicitly whether DeepSeek's `Retry-After` is forwarded verbatim or replaced. (c) Define behaviour when both are simultaneously true (upstream 429 received while local bucket is also empty).
- **Refs**: FR-5, FR-7

### Objection 8

- **Severity**: major
- **Area**: missing
- **Scenario**: 06:00, on-call is paged for "all caller requests returning 500". The proxy logs `outcome="transport_error"` for every request. Investigation reveals that overnight DeepSeek released v2 of `/v1/chat/completions` which now requires a new `tool_choice` field shape, and the proxy — being verbatim drop-through (FR-3) — passed through what callers sent. But the failure is on the *response* parsing path: the proxy attempted to read fields it never used and the JSON parser threw because DeepSeek added an unknown field at the top level whose value is a number, breaking a strict-typed deserializer. The spec's FR-3 says "verbatim, without modification, additions, or renaming of fields" — so the proxy implementation should NOT have a strict schema on the response — but the spec does not explicitly forbid the implementer from validating shape. The spec is also silent on what happens if DeepSeek deprecates a field, returns an unknown enum value, returns a new top-level error structure, or changes the `Content-Type`.
- **What to fix**: Add an FR that explicitly mandates the proxy treat both request and response as opaque byte streams (or untyped JSON pass-through) — no field-level validation, no parsing into typed structs that would reject unknown fields. Specify behaviour when upstream returns non-JSON (HTML error page from a CDN, 502 with text/plain) — does the proxy forward the body as-is with the original `Content-Type`, or rewrap into a JSON error? State the spec's policy for upstream schema drift: "the proxy is intentionally schema-agnostic; upstream changes propagate to callers without proxy modification."
- **Refs**: FR-3, FR-5, missing — no ID yet

### Objection 9

- **Severity**: major
- **Area**: edge
- **Scenario**: 05:40, callers complain the proxy "accepts non-chat traffic and just hangs." Investigation: a misconfigured internal service was POSTing to `/v1/chat/completions` with `Content-Type: text/plain` and no JSON body. The spec (FR-2) only specifies the surfaced endpoint as `POST /v1/chat/completions` — it says nothing about what the proxy does for `GET /v1/chat/completions`, `OPTIONS /v1/chat/completions`, `POST /` (root), `POST /v1/embeddings`, or any unknown path. It does not specify how the proxy validates `Content-Type` or rejects malformed JSON. It does not specify whether the proxy enforces TLS verification on the upstream connection (default Node fetch does, but a future implementer might `NODE_TLS_REJECT_UNAUTHORIZED=0` for a local mock and ship that to prod). It does not specify what happens to OPTIONS / CORS preflight. Operators have no contract to test against.
- **What to fix**: Add explicit FRs: (a) requests with HTTP method other than POST on `/v1/chat/completions` MUST return 405 Method Not Allowed; (b) requests to any path other than `/v1/chat/completions` (and the metrics path TBD) MUST return 404; (c) requests without `Content-Type: application/json` (or with malformed JSON body) MUST return 400 with a JSON error before any upstream call; (d) the proxy MUST verify upstream TLS certificates against the system trust store and MUST refuse to start if `NODE_TLS_REJECT_UNAUTHORIZED=0` is set in production. These are cheap to write down now and load-bearing for the on-call later.
- **Refs**: FR-2, FR-3, FR-4, missing — no ID yet

### Objection 10

- **Severity**: major
- **Area**: NFR
- **Scenario**: 03:55, a Prometheus scrape error alert fires: "metrics endpoint returning 500 / cardinality blow-up." Investigation: NFR-OBS-1 specifies the counter labelled by `outcome` (closed enum, six values — fine) and the histogram "unlabelled or labelled only by `outcome`" (also fine). But NFR-OBS-1 also says "metrics endpoint exposed on a metrics endpoint (path/transport TBD by architect)" — leaving open whether metrics are served on the same HTTP port as the API. If yes: anyone on the perimeter (NFR-SEC-1: no caller auth) can scrape them, including external Prometheus federations or compromised internal hosts; if no: the spec doesn't say which port, so the architect picks, the operator's Docker exposes only the API port, and metrics scraping silently doesn't work for weeks. Additionally the spec doesn't enumerate which `outcome` values can co-occur with which HTTP statuses, doesn't specify a process-up gauge, doesn't specify any upstream-error counter at HTTP-status granularity, and doesn't specify what the histogram's bucket layout MUST cover (latency_ms can be 0 for FR-7 fast-fails or 30000 for NFR-LAT-1 timeouts — a five-decade range).
- **What to fix**: Pin down: (a) metrics on a separate listening port (commonly 9090 or 9100), bound to the same network the API listens on (or document as a separate ADR-001 question), (b) require a `proxy_up` gauge and a `proxy_build_info` info metric for liveness alerting, (c) require `outcome` set is closed AND require a separate counter `upstream_status_total{code}` (low cardinality: HTTP statuses only) so per-Objection-5 distinctions are observable, (d) specify minimum histogram bucket coverage (e.g., 1ms, 10ms, 100ms, 250ms, 500ms, 1s, 2s, 5s, 10s, 14s, 30s) to give the on-call meaningful percentiles.
- **Refs**: NFR-OBS-1, NFR-SEC-1

### Objection 11

- **Severity**: minor
- **Area**: missing
- **Scenario**: 04:30, DeepSeek incident: API returns 500 with `Content-Type: application/json` but body `{"error": "internal", "request_id": "ds-abc-123"}`. Caller-side support cannot reproduce locally and asks the proxy on-call to "find request ds-abc-123 in your logs." The proxy log line for that request has the proxy-assigned `request_id` (NFR-OBS-1) but does NOT capture DeepSeek's upstream `request_id` or any upstream correlation header (e.g. `x-request-id`, `cf-ray`). Cross-correlation between proxy logs and DeepSeek-side support is impossible without a redeploy that adds the field.
- **What to fix**: Extend NFR-OBS-1's per-request log fields to include `upstream_request_id` (string, nullable) populated from a small explicit allow-list of upstream response headers (e.g., `x-request-id`, `x-deepseek-request-id`, `cf-ray`). Confirm this does not violate the headers-not-logged rule: the rule's intent is PII safety, opaque upstream correlation ids are not PII.
- **Refs**: NFR-OBS-1

### Objection 12

- **Severity**: minor
- **Area**: edge
- **Scenario**: 02:00, the proxy process spikes RSS to 1.2 GiB and is OOM-killed by Docker (default container memory limit is whatever the operator set; the spec doesn't specify). Investigation: a caller sent a 150 MB JSON request body (allowed: no body-size cap per Objection 2). Node's default fetch buffers the body in memory, then forwards it upstream. Multiple concurrent oversize requests pin memory and the kernel kills the process. The spec is silent on memory budgeting, container resource limits, and Node heap settings (`--max-old-space-size`).
- **What to fix**: Add an NFR-DEP-2 amendment specifying recommended container memory limit (e.g., 512 MiB) and corresponding Node flag `--max-old-space-size`. Combined with the body-size cap from Objection 2, this gives a deterministic upper bound on memory and prevents trivial DoS.
- **Refs**: NFR-DEP-2, NFR-CAP-1

## Self-rating pass

| # | Depth (deep / medium / shallow) | Reason for the rating |
|---|---------------------------------|-----------------------|
| 1 | deep    | Names a specific timing race with arithmetic, identifies the missing abort-propagation FR, and points to the double-billing consequence. The fix is concrete (lower NFR-LAT-2 to 12 s OR widen NFR-LAT-1 to 32 s OR mandate cancel-on-walltime). |
| 2 | deep    | Threat-model gap with concrete consequence (4× bill spike, no attribution), three independent specific fixes (caller_id logging, body cap, accept-or-mitigate the perimeter assumption). Hits multiple spec sections. |
| 3 | deep    | Identifies an enforcement gap between "single-instance only" prose and the lack of mechanism. Rolling deploys are normal operator behaviour; the spec's only defence is wording. Three concrete remediations offered. |
| 4 | deep    | Quantitative contradiction (5 s drain vs. 14–30 s request lifetime) directly readable from the spec. The fix is binary (widen drain or document the kill behaviour) and the runbook angle is real. |
| 5 | deep    | Distinguishes 502 (transport-shaped) from 500 (real server error) with a specific edge-LB scenario, and exposes the observability gap (no upstream status code in metrics). Two-part fix with clear acceptance criteria. |
| 6 | deep    | Specific scenario (caller TCP RST mid-response → caller retry → double billing), specific missing artifacts (X-Request-Id response header, idempotency-key contract). Spec is silent in a way that will hurt support workflows. |
| 7 | medium  | The Retry-After contradiction is real and load-bearing. Slightly less acute than the timing/enforcement objections because the worst case is over-advising callers, but the upstream-vs-local ambiguity is genuinely unspecified. |
| 8 | medium  | Schema-drift exposure is a real long-term failure mode. Less likely to wake on-call in week one, more likely in month six when DeepSeek ships a v2 field. The fix (forbid typed deserialization) is concrete and small. |
| 9 | medium  | Method/path/Content-Type/TLS strictness is genuinely missing and concrete. Each sub-item is small but the package adds up to a real contract gap; the TLS-verification one is the most acute. |
| 10 | medium | Metrics surface and cardinality concerns are real and the per-status-code counter ties back to Objection 5. The bucket layout sub-fix is on the lower end of severity but the metrics-port-and-auth concern is load-bearing. |
| 11 | medium | Cross-correlation between proxy logs and DeepSeek support is a recurring real-world need. Minor severity because the fix is small and the impact is debuggability rather than outage. |
| 12 | medium | Memory/OOM scenario is realistic only if Objection 2's body cap is rejected, but stands on its own as a deployment hardening gap. Concrete fix (memory limit + heap flag). |

All 12 objections survive the self-rating pass at medium or deep. None are duplicates; none are generic "consider monitoring" placeholders.

## Verdict

- **Verdict**: needs-changes
- **Justification**: Blocking on objections 1 and 2. Objection 1 is a quantitative timing contradiction with no abort-propagation contract — at 30 s wall-time and 14 s per-attempt retry, the proxy will routinely race itself, return 504 to callers, and continue burning DeepSeek quota in the background; this MUST be resolved before ADRs commit to a cancellation strategy. Objection 2 names an unbounded blast radius (no caller auth + no inbound rate limit + no body cap + perimeter trust + shared upstream key) that will be exploited the first time an internal service misbehaves and there is no spec-mandated way to detect or stop it. Objections 3, 4, 5, 6 are major and must be addressed before ADRs (single-instance enforcement vs deploy overlap; drain window vs request lifetime; retry policy vs upstream 502; idempotency and X-Request-Id surface). Objections 7, 8, 9, 10 are major and should be folded into the spec in the same revision pass; objections 11, 12 can be deferred to architect-stage notes if needed but cost little to add now. The spec is well-written prose with several genuinely well-thought sections (the FR-5 retry rationale, the FR-7 immediate-rejection contract), but its load-bearing assumptions about timing, enforcement of single-instance, and trust boundaries do not survive contact with realistic 3am scenarios.
