# Spec: deepseek-client

## Goal

A standalone HTTP proxy/gateway service that sits in front of the DeepSeek LLM API and provides retry, rate limiting, streaming, provider-error handling, timeouts, and observability to its callers.

## Functional requirements

- **FR-1**: The proxy holds the upstream DeepSeek API key server-side as part of its own configuration. Callers MUST NOT supply DeepSeek credentials; the proxy injects the upstream `Authorization` header itself when forwarding to DeepSeek.
- **FR-2**: The proxy exposes a single upstream-mirroring endpoint: `POST /v1/chat/completions`. No other DeepSeek endpoints are surfaced in this iteration.
- **FR-3**: The proxy mirrors DeepSeek's `POST /v1/chat/completions` request and response JSON schemas verbatim, without modification, additions, or renaming of fields. Drop-in compatibility goal: a caller already using the DeepSeek SDK / raw HTTP client MUST be able to switch to the proxy by changing only the base URL (and removing the upstream API key from the client side, since FR-1 injects it server-side).
- **FR-4**: This iteration handles non-streaming chat completions only. The proxy MUST accept requests where `"stream"` is `false` or omitted (defaulting to non-streaming). Requests with `"stream": true` MUST be rejected with HTTP 400 and a JSON error body explaining that streaming is not supported in this iteration; the proxy MUST NOT silently downgrade `stream: true` to `stream: false`.
- **FR-5**: Retry policy — only transport-level failures trigger automatic retry. Specifically: DNS resolution failure, TCP connection error (ECONNREFUSED / ECONNRESET / EHOSTUNREACH / ENETUNREACH), TCP reset mid-flight before any HTTP response bytes have been received, TLS handshake error, and read timeout BEFORE any response bytes have been received from upstream. Any HTTP response received from upstream — including all 4xx and all 5xx (e.g. 429, 500, 502, 503, 504) — MUST be forwarded to the caller as-is and MUST NOT be retried. The cutoff is "before any response bytes received": once the upstream has begun sending a response, the proxy assumes the request may have been (partially) processed and does not retry. Rationale: chat completions are non-idempotent on the upstream side (billing, generation state); retrying after upstream may have processed the request risks double billing and divergent generations for the same logical call.
- **FR-6**: Retry budget (conservative profile). Maximum attempts per logical caller request = **2** (1 initial attempt + at most 1 retry). Backoff between the initial attempt and the retry = **fixed 500 ms with ±20% uniform jitter** (i.e. a delay drawn uniformly from [400 ms, 600 ms]). The retry budget applies only to the transport-level failure classes enumerated in FR-5; it does not apply to upstream HTTP responses. The total wall-time cap for the entire logical call (including the initial attempt, the jittered backoff sleep, and the retry attempt) is governed by NFR-LAT-1.
- **FR-7**: Outbound rate-limit overflow behavior. When the outbound rate cap (NFR-CAP-1) is exhausted at the moment a caller request would be issued upstream, the proxy MUST respond to the caller immediately with HTTP **429 Too Many Requests** and a `Retry-After` header whose value is the number of whole seconds (rounded up, minimum 1) until the next outbound token becomes available under the configured token bucket. The response body MUST be a JSON error object indicating "outbound capacity exhausted". The proxy MUST NOT queue, buffer, or delay the request internally waiting for capacity; rejection is immediate. This applies before any upstream call is attempted, so FR-5/FR-6 retry semantics are not engaged for 429-overflow.

> Each FR has a stable ID (FR-N). Reviews and ADRs reference these IDs.

## Non-functional requirements

### Latency

- **NFR-LAT-1**: Total wall-time per logical caller request, measured from the moment the proxy begins handling the inbound request to the moment it begins writing a response to the caller, MUST NOT exceed **30 seconds**. This budget includes: the initial upstream attempt, any jittered backoff sleep (per FR-6), and any retry attempt. If the budget is exceeded before a usable upstream response is available, the proxy MUST abort further work and respond to the caller with HTTP **504 Gateway Timeout** and a JSON error body. The 30 s cap is a hard ceiling, not a percentile target; it applies to every request (effectively p100). Sizing rationale: per-attempt budget (NFR-LAT-2) is 14 s, jittered backoff (FR-6) is up to 0.6 s, two attempts (FR-6) → worst case 14 + 0.6 + 14 = 28.6 s, fits within 30 s with ~1.4 s headroom for proxy-internal overhead.
- **NFR-LAT-2**: Per-attempt upstream timeouts (each individual attempt to DeepSeek, applied independently to the initial attempt and to the retry attempt under FR-6). **TCP connect timeout: 3 seconds** (from socket() to established TCP+TLS). **First-byte (time-to-first-byte) timeout: 14 seconds** (from request bytes flushed to first response byte received from upstream). **Total per-attempt timeout: 14 seconds** (hard cap on a single attempt's wall-time, inclusive of connect + send + first byte + body read). Exceeding the connect timeout or the first-byte timeout before any response bytes have been received counts as a transport-level failure for the purposes of FR-5 and is eligible for retry within the FR-6 budget. Exceeding the total per-attempt timeout AFTER response bytes have begun arriving is NOT retried (per FR-5 cutoff) and surfaces as 504 to the caller if NFR-LAT-1 wall-time also expires.

### Throughput

- **NFR-THR-1**: Sustained throughput target — **5 RPS** with a **burst of 5** — bounded by and equal to the outbound token-bucket configuration in NFR-CAP-1. The proxy does not target a higher throughput than the outbound cap allows; inbound bursts that would exceed the available outbound tokens are rejected immediately per FR-7 (429 + `Retry-After`), not queued. There is no separate inbound throughput throttle.
- **NFR-CAP-2**: Expected inbound load profile (forecast, not a guarantee). **Sustained inbound rate: < 1 RPS** under normal operating conditions. **Peak inbound rate: < 3 RPS** during short-lived bursts. **Growth horizon: 12 months, flat** — no organic growth in caller traffic is expected over the next year; this profile is the planning baseline for the iteration. Relationship to NFR-CAP-1: the configured outbound cap (5 RPS, burst 5) leaves a comfortable margin above expected peak inbound (3 RPS), so FR-7 (immediate 429 + Retry-After on outbound bucket exhaustion) is expected to fire only on anomalous traffic spikes well above the forecast envelope, not in steady-state operation.

### Availability / SLA

- **NFR-AVL-1**: Best-effort availability. The proxy makes **no monthly availability commitment** (no 99% / 99.9% / 99.95% SLO) in this iteration. Rationale: single-instance deployment (per NFR-DEP-2) cannot honestly support a multi-nine SLO, and the proxy is an internal tool behind a perimeter-trusted network (NFR-SEC-1) with low forecast traffic (NFR-CAP-2), so a formal availability target would be theatre rather than a real commitment. Operational expectations the proxy MUST meet:
  - **Graceful shutdown on SIGTERM**: on receiving SIGTERM, the proxy MUST stop accepting new inbound caller requests and MUST attempt to drain in-flight requests (let them complete or time out per NFR-LAT-1) within an approximately **5-second** drain window before exiting. After the drain window, remaining in-flight requests MAY be terminated.
  - **Process restart on crash**: the deployment platform's supervisor (e.g. systemd `Restart=always`, `docker run --restart=always` / Compose `restart: unless-stopped`, k8s Deployment / ReplicaSet) is expected to restart the proxy process automatically on crash or non-zero exit. Choice of supervisor is captured in the Deployment NFR.
  - **No HA, no failover, no multi-region, no active-passive standby** in this iteration. A single instance going down means downtime until the supervisor restarts it; callers are expected to tolerate this.

### Durability

- **NFR-DUR-1**: The proxy is **stateless**. It holds no persistent state across process restarts: no database, no on-disk queue, no cache file, no journal. In-flight requests at the moment of crash or SIGTERM are lost (callers will see a connection error or, during graceful shutdown, observe FR-7/NFR-LAT-1 outcomes per the drain window in NFR-AVL-1). **RPO (Recovery Point Objective) = N/A** — there is no committed data to recover. **No data-loss model is required** for this iteration; durability is intentionally not a concern of this service.

### Security

- **NFR-SEC-1**: The proxy MUST NOT be exposed to untrusted networks. Deployment assumes a closed network / VPC / service mesh with perimeter trust; the proxy itself enforces no caller authentication or authorization. Any client able to reach the proxy on the network is treated as authorized. **Secret-in-logs prohibition**: the upstream DeepSeek API key (sourced from `DEEPSEEK_API_KEY`, see NFR-DEP-2) MUST NOT appear in any stdout/stderr log line — ever, on any code path, including error/diagnostic paths. NFR-OBS-1 already forbids logging request/response bodies and headers; this constraint extends that prohibition explicitly to the API key value, so that incidental error-handling code (e.g. `console.log(error)` dumping a serialized request object that includes the `Authorization` header) does not leak the secret. Implementers MUST scrub or redact any log site that could plausibly serialize a request object, headers map, or error containing the key.

### Observability

- **NFR-OBS-1**: Minimal observability profile for this iteration.
  - **Logging**: structured JSON logs written to **stdout** at levels INFO / WARN / ERROR. Exactly **one log line per inbound caller request**, emitted at request completion, with the following fields:
    - `request_id` — proxy-assigned correlation id (string).
    - `status` — the HTTP status code returned to the caller (integer).
    - `latency_ms` — caller-visible end-to-end latency, measured from inbound request received to first response byte written to caller (integer milliseconds).
    - `upstream_latency_ms` — sum of wall-time spent on upstream attempts (initial + retry, if any), excluding jittered backoff sleep (integer milliseconds; 0 if no upstream call was made, e.g. FR-7 immediate 429).
    - `retry_count` — number of retries actually performed (0 or 1, per FR-6).
    - `outcome` — closed enum, exactly one of: `ok`, `rate_limited` (FR-7 outbound overflow → 429), `gateway_timeout` (NFR-LAT-1 wall-time exceeded → 504), `upstream_5xx` (DeepSeek returned 5xx, forwarded as-is), `transport_error` (all transport-level failures from FR-5 exhausted retries), `client_error` (4xx returned to caller, e.g. FR-4 stream-rejection 400 or upstream 4xx forwarded).
  - **PII / payload safety**: the proxy MUST NOT log inbound request bodies, outbound upstream request bodies, upstream response bodies, or caller response bodies. Headers MUST NOT be logged either, except that the proxy MAY log the presence/absence of opaque correlation headers it itself sets. This is an explicit safety choice: chat prompts and completions are treated as sensitive.
  - **Metrics**: Prometheus-style metrics exposed on a metrics endpoint (path/transport TBD by architect). Required metrics in this iteration:
    - A **counter** of completed caller requests, labelled by `outcome` (same closed enum as the log field).
    - A **histogram** of caller-visible latency (same value as `latency_ms`), unlabelled or labelled only by `outcome`; bucket layout left to the architect.
  - **Tracing**: no distributed tracing (no OTel spans, no W3C traceparent propagation) in this iteration. See Out of scope.

### Capacity

- **NFR-CAP-1**: The proxy MUST enforce an **outbound** rate cap on its own request flow to DeepSeek (i.e. the proxy throttles itself before issuing upstream calls), to avoid triggering upstream 429 storms. The cap is implemented as a **token bucket** with a **steady-state rate of 5 requests/second** and a **burst capacity of 5 tokens** (i.e. up to 5 requests may be issued back-to-back from a full bucket; the bucket then refills at 5 tokens/sec). The cap is **process-wide** within a single proxy instance and applies to all outbound DeepSeek calls regardless of caller. There is no inbound rate limit applied to callers — the proxy does not police caller request rates. Overflow behavior (rejection semantics when the bucket is empty) is specified in FR-7.

### Dependencies

- **NFR-DEP-1**: External dependencies and runtime baseline.
  - **Upstream provider**: DeepSeek REST API. Default base URL `https://api.deepseek.com`, overridable at deployment time via an environment variable (e.g. `DEEPSEEK_BASE_URL`) to support staging/test endpoints or a local mock; the default MUST be the production DeepSeek endpoint.
  - **Upstream auth**: HTTP header `Authorization: Bearer <DEEPSEEK_API_KEY>`, where `DEEPSEEK_API_KEY` is supplied per NFR-DEP-2 and protected per NFR-SEC-1.
  - **Runtime**: Node.js LTS, specifically version **v20 or v22**. Older or non-LTS Node versions are not supported.
  - **OS / architecture**: linux/amd64 (the Docker base image and CI build target).
  - **No fallback provider**: if DeepSeek is unreachable, requests fail per FR-5 (transport-level retry exhausted → `transport_error` outcome) or surface upstream HTTP responses verbatim. Routing to an alternative LLM provider is explicitly out of scope (see §Out of scope, multi-provider).

### Deployment

- **NFR-DEP-2**: Deployment topology and secret delivery.
  - **Runtime**: a single Node.js process running inside a Docker container. One container = one proxy instance.
  - **Supervisor**: the Docker daemon. The container MUST be started with a restart policy equivalent to `--restart=always` (plain `docker run`) or `restart: unless-stopped` / `restart: always` in Docker Compose. No external supervisor (systemd, Kubernetes, Nomad) is assumed in this iteration.
  - **Configuration transport**: all runtime configuration is passed via **environment variables** at container start. No config files, no config server, no runtime mutation.
  - **Secret delivery**: the upstream DeepSeek API key is supplied as the `DEEPSEEK_API_KEY` environment variable. There is no integration with a secrets manager (Vault, AWS Secrets Manager, GCP Secret Manager, Kubernetes Secret, Docker secret, etc.) in this iteration. Operator responsibilities: (a) keep the source of `DEEPSEEK_API_KEY` (e.g. `.env` file, CI variable, host shell export) out of version control, (b) avoid surfaces that echo container env to other tenants (shared `docker inspect`, unrestricted `ps`/`/proc`), (c) rotate the key by restarting the container with a new value. The proxy itself enforces NFR-SEC-1's secret-in-logs prohibition on the runtime side.
  - **Deployment cadence**: manual or via simple CI (e.g. build image, push, `docker compose pull && up -d`). No specific CD pipeline is mandated by this spec; left to the operator.
  - **Single-instance only**: this iteration ships exactly one running proxy instance. Horizontal scaling / multi-replica deployment is explicitly out of scope (rationale: NFR-CAP-1's token bucket is process-local; running N replicas would multiply the effective outbound rate to N × 5 RPS and silently break the upstream cap contract).

## Out of scope

- Multi-provider support (OpenAI, Anthropic, etc.). This iteration targets DeepSeek only; "any other LLM provider" is aspirational and not a requirement now.
- Caller authentication and authorization. The proxy does not authenticate or authorize its callers; the trust boundary is the network perimeter (closed network / VPC / service mesh). See NFR-SEC-1.
- Other DeepSeek endpoints (text completions, embeddings, models list, FIM/beta endpoints, etc.) — not exposed in this iteration. Only `POST /v1/chat/completions` is surfaced. See FR-2.
- SSE / streaming pass-through (`"stream": true`) — deferred to a future iteration. The Goal statement mentions "streaming" as an aspirational capability of the proxy family, but for this iteration streaming is explicitly out. See FR-4.
- Distributed tracing — deferred. No OpenTelemetry spans, no W3C `traceparent` propagation, no Jaeger/Tempo/Zipkin export in this iteration. Observability is limited to the minimal stdout-JSON-logs + Prometheus-counters/histogram profile of NFR-OBS-1. Reason: keep the iteration small; tracing can be layered in later without breaking the wire contract.
- Logging of request/response bodies and headers — explicitly excluded for PII safety. See NFR-OBS-1.

## Open assumptions

> Interviewer-agent records assumptions here in the form `[ASSUMED: <statement> — <reason / source>]`.
> Each assumption MUST be explicitly confirmed or denied by the developer before §Approval.

- (none)

## Approval

> Developer writes `approve` and the date below. Without this, no downstream stage may proceed.

- Status: approved
- Approved by: Sergey Puhoff
- Date: 2026-04-30
