# ADR-006: 30-second graceful drain with proxy_up flip and Connection: close

## Status

proposed

## Context

NFR-AVL-1 mandates a graceful-shutdown contract on SIGTERM with a drain window
**≥ NFR-LAT-1** (i.e., ≥ 30 s). New connections during drain must be rejected
with HTTP 503 + `Connection: close`. In-flight requests must be allowed to
either complete or hit their NFR-LAT-1 wall-time. The `proxy_up` gauge
(NFR-OBS-1) must transition `1 → 0` at the start of drain.

The original spec had a 5-second drain window; spec-review objection 4 named
this as a contradiction with NFR-LAT-1 / NFR-LAT-2 (a single attempt can take
12 s, two attempts up to 24.6 s, plus event-loop slack). The amended spec
fixes the prose (drain ≥ 30 s); this ADR pins the implementation, including
the Docker-side requirement that `stop_grace_period` (or `--time` on
`docker stop`) be raised from its default 10 s to ≥ 30 s — otherwise the
container is SIGKILLed mid-drain and the spec is silently violated.

This ADR **resolves spec-review objection 4** (drain window vs request
lifetime) by anchoring both the proxy code and the deployment contract.

- Drives: NFR-AVL-1, NFR-LAT-1, NFR-OBS-1 (`proxy_up` flip), FR-9 (single-port
  bind), NFR-DEP-2 (deploy procedure).
- Resolves: spec-review objection 4 (drain window reconciled with
  per-request lifetime).

## Alternatives

### Alternative A: `server.close()` with explicit connection tracking and a 30-second drain timer

- **Cost**: ~50 LOC. No dependencies; we can use Fastify's `onClose` hook plus a
  `Set<Socket>` populated on the API server's `connection` event.
- **Complexity**: One SIGTERM handler. We call `apiServer.close()` (which stops
  accepting new connections immediately) but do NOT call `socket.destroy()` on
  in-flight sockets — they continue to serve their request to completion or to
  their wall-time, whichever first. After 30 s we forcibly destroy any remaining
  sockets and exit.
- **Correctness**: Fastify v4's `server.close(callback)` resolves the callback
  when all connections have closed naturally. Combined with the wall-time guard
  in ADR-002 (every in-flight request will hit its NFR-LAT-1 30-s ceiling at the
  same time as our drain timer), the natural close happens before the forced
  destroy almost always.
- **Operability**: We can log the drain progress (number of sockets remaining,
  countdown) at INFO every 5 s during drain — useful for the operator's runbook
  step "wait for drain".
- **Verdict**: chosen — direct mapping from NFR-AVL-1 prose to code; no library
  needed.

### Alternative B: `terminus` library (`@godaddy/terminus`)

- **Cost**: One dependency, primarily intended for k8s readiness/liveness
  integration.
- **Complexity**: terminus wraps `server.close` plus health checks plus drain.
  Configurable, but its abstraction (lifecycle states `serving`, `shutting-down`,
  `closing`) is overkill for our two-listener single-instance setup.
- **Correctness**: Equivalent in correctness if configured for a 30-s timeout
  and a manual `proxy_up` flip; we write equivalent code one layer deeper.
- **Operability**: Adds an opaque framework log surface; `terminus` debug logs
  do not flow through pino's redact pipeline by default, a small NFR-SEC-1 risk
  if any of its diagnostic prints contain headers.
- **Verdict**: rejected — value-add is "structured drain lifecycle" we don't
  need; the hidden log surface is a redaction risk.

### Alternative C: Hard SIGTERM = `process.exit(0)` immediately, no drain

- **Cost**: Zero LOC.
- **Complexity**: None.
- **Correctness**: Violates NFR-AVL-1 outright. Every in-flight request is
  killed with TCP RST or empty response — exactly the failure spec-review
  objection 4 named.
- **Operability**: Operators run a single `docker compose stop`, no drain,
  callers retry, double bills happen.
- **Verdict**: rejected — directly contradicts NFR-AVL-1; included only to
  illustrate the cost of the chosen alternative.

## Decision

We implement Alternative A. SIGTERM handler:

```
let drainStart = null;
let drainTimer = null;

process.on('SIGTERM', async () => {
  if (drainStart) return;          // idempotent
  drainStart = Date.now();
  log.info('SIGTERM received, beginning drain');
  proxyUpGauge.set(0);             // NFR-OBS-1, immediately observable on /metrics

  // Stop accepting new inbound connections on the API listener.
  // Fastify's preClose/onClose hooks coordinate the actual lifecycle.
  await apiServer.close();

  // Metrics listener stays UP throughout drain so Prometheus can still scrape
  // proxy_up=0 and the operator/runbook can confirm drain is in progress.
  // It is closed only after the API server is fully drained.

  drainTimer = setTimeout(() => {
    log.warn('Drain timeout reached, forcing shutdown');
    forceCloseAllSockets();
    process.exit(0);
  }, 30_000);
});
```

While `apiServer.close()` is pending, Fastify will not accept new connections
on the API port, but already-accepted connections continue serving. We add a
**preHandler hook** that fires only when `proxyUpGauge.value === 0` and the
request has not started body forwarding yet — that hook responds with HTTP 503
+ `Connection: close` + the spec's JSON error envelope. This catches the race
window where a TCP connection slipped in between the SIGTERM and `server.close`
returning. Pure TCP-level rejection of new connections is the kernel's job once
`apiServer.close()` has returned and the listening socket is gone.

The metrics listener stays up during drain (the drain timer at the end closes
it, then `process.exit(0)`). This is **load-bearing** for the deploy runbook
step "Verify by hitting `/metrics` and confirming `proxy_up == 1`": during
drain, scraping `/metrics` returns `proxy_up == 0`, which is the explicit
signal that the old container is leaving.

**Docker-side contract.** The proxy's drain is correct only if the supervisor
gives it 30 seconds. The default Docker stop grace period is 10 s, which is a
**misconfiguration** under our spec. The `docker-compose.yml` MUST include:

```yaml
services:
  deepseek-client:
    stop_grace_period: 30s
    stop_signal: SIGTERM
```

ADR-007 (build / deploy topology) repeats this requirement and includes it in
the Dockerfile / compose templates we ship.

This **resolves spec-review objection 4**: the drain window is now 30 s
(matching NFR-LAT-1 wall-time), the connection-level rejection contract is
named (503 + `Connection: close`), and the deploy contract is explicit
(`stop_grace_period: 30s`).

## Consequences

### Positive

- Drain window matches request lifetime: the worst case is 24.6 s (FR-6 + 2 ×
  NFR-LAT-2) plus event-loop slack < 5.4 s, all within 30 s.
- `proxy_up` flips at the start of drain so Prometheus / operator / dashboard
  see the state change *before* the API listener has fully closed — useful
  for staged drain monitoring.
- 503 + `Connection: close` for the rare new-connection-during-drain case
  gives callers an actionable signal (their existing connection will be torn
  down; new requests should go elsewhere or back off).
- Metrics listener stays up throughout drain so the deploy runbook step
  ("hit `/metrics`, confirm `proxy_up == 0`") works.

### Negative

- The `stop_grace_period: 30s` requirement is now a **deployment-side
  contract** that the proxy cannot enforce on its own — an operator who
  ignores it ships a silently-non-compliant deploy. ADR-007 will document
  this in the runbook and the Docker template; we accept that "operator
  reads the runbook" is part of NFR-AVL-1's blast radius.
- 30 s of drain on every deploy doubles the deploy window the operator must
  wait for compared to a 5-s drain. Acceptable: deploys are infrequent and
  NFR-AVL-1 is best-effort.
- Forced socket destruction at the 30-s mark **does** kill in-flight requests
  that hit their wall-time at 30.0001 s. Edge case: an inbound request that
  arrived 0.5 s before SIGTERM has 29.5 s of remaining wall-time; the drain
  timer fires before its wall-time, and the proxy has destroyed the socket.
  Caller sees TCP RST. The spec accepts this as the practical floor.
- Stop-then-start deploys (NFR-DEP-2) mean callers see a 30-s availability
  gap on every deploy. Acceptable per NFR-AVL-1's "best-effort, no SLA";
  flagged in ADR-007.

## Open questions

- Should we also handle SIGINT (Ctrl-C in interactive containers) the same
  way? Reasonable default: yes, mirror SIGTERM. The arch-reviewer can
  challenge whether SIGINT should hard-exit instead for dev ergonomics.
- The drain progress log line (every 5 s) is a derived control not in the
  spec. We add it because it is operationally cheap; the arch-reviewer may
  push to formalise it as part of NFR-OBS-1.
- The NFR-AVL-1 prose says "in-flight requests MAY be terminated after the
  drain window". We choose to **forcibly destroy** sockets at the drain
  window end (rather than `process.exit` and let the kernel sort it). The
  arch-reviewer may push to leave it to the kernel; we prefer explicit
  cleanup so log lines for the abandoned requests get written first.
