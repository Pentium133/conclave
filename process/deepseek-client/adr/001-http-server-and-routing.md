# ADR-001: Use Fastify with raw-body handling for the inbound HTTP surface

## Status

proposed

## Context

The proxy must stand up two distinct HTTP listeners (API on `8080`, metrics on `9090`),
enforce strict method/path/Content-Type semantics on the API listener (FR-12), and forward
the inbound request body to DeepSeek as opaque bytes without typed deserialization (FR-3,
FR-11). The framework choice is load-bearing because most Node.js HTTP frameworks default
to body parsing (which would either reject unknown JSON shapes or rebuild the JSON, both
of which break FR-11's "no field-level validation, no rewriting" guarantee). The framework
must also make `bind-or-die` (FR-9) trivial and let us peek at the inbound bytes only as
much as FR-4 (`stream` field detection) and FR-8 (Content-Length cap) require.

This ADR responds to spec-review **objection 9** (no spec'd 405 / 404 / 415 contract)
and to spec-review **objection 8** (FR-3 verbatim pass-through must be the implementation
contract, not just the prose contract).

- Drives: FR-2, FR-3, FR-4, FR-8, FR-9, FR-11, FR-12, NFR-CAP-2, NFR-DEP-1.
- Resolves: spec-review objection 9 (HTTP surface strictness), spec-review objection 8
  (no typed deserialization on the request side).

## Alternatives

### Alternative A: Fastify with `addContentTypeParser('application/json', { parseAs: 'buffer' }, (_req, body, done) => done(null, body))`

- **Cost**: One additional dependency at runtime; trivial install size next to `pino`
  and `prom-client`.
- **Complexity**: Routing, 405 / 404 hooks, two-listener setup, and `onRequest` /
  `preHandler` lifecycle are all first-class. Custom buffer-as-body parser is ~6 lines.
- **Correctness**: We can register a single route `POST /v1/chat/completions`, return the
  body as a `Buffer`, and rely on Fastify's default `notFoundHandler` (404) and
  per-route `405` (via `routerOptions`) to satisfy FR-12 without writing it ourselves.
  The buffer body is forwarded byte-for-byte to undici (ADR-002), so FR-3 / FR-11 hold by
  construction.
- **Operability**: Built-in request lifecycle hooks make `request_id` injection on
  `onRequest`, `X-Request-Id` emission on `onSend`, and metrics on `onResponse`
  natural; no monkey-patching of `node:http`.
- **Verdict**: chosen — only option that gives us strict-routing-by-default, raw-body
  pass-through, and a first-class hook surface for FR-10 / NFR-OBS-1 in a few dozen
  lines of code.

### Alternative B: Express 4 with `express.raw({ type: 'application/json', limit: '256kb' })`

- **Cost**: Mature ecosystem, but Express 4 has no second-listener helpers and its
  router happily returns `200` for unknown paths if you forget to wire the catch-all.
- **Complexity**: Manually implementing 404, 405 (with `Allow` header), and 415
  middleware is repetitive; `express.raw` does enforce `Content-Type` but does not
  cleanly emit 415 — it just no-ops, so requests with `text/plain` reach the handler
  with `req.body === {}`, easy to fail-open.
- **Correctness**: Default Express patterns expose FR-11 violations through the
  middleware stack (logging, body-parsing layered on `req`); the proxy author has to
  remember to opt out of all of them. One careless `express.json()` import and the
  body becomes a typed object that drops unknown fields' byte order.
- **Operability**: No built-in two-listener convenience; `app.listen()` × 2 works but
  the metrics route would have to live on a separate Express app.
- **Verdict**: rejected — fail-open defaults on Content-Type and 404 violate FR-12
  unless we add layers of guard middleware, and the raw-body discipline is brittle.

### Alternative C: Bare `node:http` with a hand-rolled router

- **Cost**: Zero external dependencies for the listener itself.
- **Complexity**: Router, method/path/Content-Type checks, error responses, JSON error
  body shaping, and `request_id`/`X-Request-Id` plumbing all hand-coded — easily
  300+ LOC and the surface most likely to drift from the spec under maintenance.
- **Correctness**: Maximum control over the body bytes (`req` is a stream, no parser
  in the way). FR-11 holds trivially.
- **Operability**: Every operational hook (logging, metrics, request id) is bespoke.
  Nothing exists for graceful close on SIGTERM (NFR-AVL-1) — must be wired to
  `server.close()` and connection tracking by hand.
- **Verdict**: rejected — saves a dep but multiplies the test surface and the
  opportunities to silently violate FR-12 / FR-10 / NFR-AVL-1 hooks.

## Decision

We adopt **Fastify** for both listeners with a custom `application/json` parser that
returns the raw `Buffer`. The single API route is `POST /v1/chat/completions`. FR-12
strict 405 / 404 / 415 are implemented as:

- `405`: Fastify's per-route method handler (`fastify.route({ method: 'POST', url: '/v1/chat/completions', ... })`)
  plus a wildcard route `fastify.all('/v1/chat/completions', ...)` that returns 405 with
  `Allow: POST` for any non-POST method on the same path.
- `404`: Fastify's default `setNotFoundHandler` returns the spec's JSON error envelope.
- `415`: We register the JSON content-type parser to call `done(new Error('UNSUPPORTED_MEDIA_TYPE'))`
  whenever the inbound `Content-Type` is absent or not `application/json`
  (case-insensitive media-type match, charset parameter ignored), and translate that
  error to a 415 in `setErrorHandler`. The malformed-JSON case is NOT validated here —
  per FR-12, malformed JSON inside `application/json` is forwarded upstream.
- `413` (FR-8): we cap `bodyLimit: 256 * 1024` on the parser (Fastify rejects with 413
  natively when `Content-Length` exceeds it). Requests without `Content-Length` are
  rejected with 411 in an `onRequest` hook before any body reads.
- FR-4 stream detection: after the buffer is captured (under the 256 KiB cap), we run
  a substring check for the literal token `"stream":true`/`"stream": true` against the
  raw bytes. No `JSON.parse`. Detection of `true` triggers a 400 response.

The metrics listener is a second `Fastify` instance bound to `METRICS_PORT`, exposing
`/metrics` and `/healthz`. Both servers register a SIGTERM handler that switches the
`proxy_up` gauge to `0` and drives ADR-006's drain.

This addresses **objection 9** end-to-end: every method/path/Content-Type rejection
is now implemented in code paths required by the framework's lifecycle, not as
documentation. It addresses **objection 8** by making "buffer-in, buffer-out" the
only viable code path — there is no `JSON.parse` of the inbound body anywhere.

## Consequences

### Positive

- FR-12's strict surface is enforced by lifecycle hooks, not by ad hoc middleware.
- FR-11 verbatim pass-through is structural: the handler receives `Buffer`, not a
  parsed object, so no field is named in source code.
- Two-listener topology required by NFR-OBS-1 / FR-9 is one helper call away.
- Fastify's hook surface gives us a clean place to set `request_id` (FR-10) on
  `onRequest` and emit the per-request log line (NFR-OBS-1) on `onResponse`.

### Negative

- One more runtime dependency (Fastify v4) we now own the upgrade path for; we accept
  the long-term security-update burden in exchange for the boilerplate it saves.
- Fastify's strict Content-Type matching is configuration, not code we control: a
  Fastify minor that loosened the matcher would silently widen our 415 contract. We
  pin a major and treat the parser-registration call as test-covered (an integration
  test that POSTs `text/plain` and asserts 415 is mandatory; the test exists to fail
  the day Fastify changes the contract).
- Custom JSON parser bypasses Fastify's schema validation features for the route — we
  cannot retrofit per-route validation later without breaking FR-11. Acceptable: FR-11
  is the spec, validation is the violation.
- We pay a small per-request CPU cost for two Fastify lifecycle traversals instead of
  one (request + onSend); negligible at the NFR-CAP-2 < 3 RPS forecast.

## Open questions

- Should the `notFoundHandler` differentiate `OPTIONS` (CORS preflight) from a generic
  unknown path? Spec is silent; default 404 is consistent with FR-12. The arch-reviewer
  may push for an explicit OPTIONS = 405 to keep CORS behaviour predictable.
- The 411-on-missing-Content-Length policy is the spec's stance (FR-8) but Fastify's
  default is to accept chunked bodies. We will add an `onRequest` hook to enforce 411,
  but a future Fastify behaviour change could surprise us; this is a test-covered
  invariant, not a Fastify-guaranteed one.
