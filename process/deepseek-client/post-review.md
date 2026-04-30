# Post-implementation review: deepseek-client (token-bucket chunk)

> Audit scope: the outbound token-bucket algorithm chunk only — `src/token-bucket.ts`
> + `tests/token-bucket.test.ts` + supporting `package.json`, `tsconfig.json`,
> `vitest.config.ts`. The HTTP surface, retry orchestrator, observability stack,
> shutdown lifecycle, deploy topology, and all other ADRs are explicitly out of
> scope for this audit; only NFR-CAP-1, NFR-THR-1, FR-7, and ADR-004 are
> load-bearing here, with NFR-DEP-1 (zero runtime deps) verified at the manifest
> level. All other FR/NFR/ADR rows are marked `out-of-scope` with a one-line
> justification.

## Per-FR check

| FR-ID | Status | Evidence (file:line) | Notes |
|-------|--------|----------------------|-------|
| FR-1  | out-of-scope | n/a | Auth-injection lives in HTTP server / upstream client; not in this chunk. |
| FR-2  | out-of-scope | n/a | Endpoint exposure is Fastify routing (ADR-001), not in scope. |
| FR-3  | out-of-scope | n/a | Schema pass-through is HTTP layer, not in scope. |
| FR-4  | out-of-scope | n/a | Stream-flag rejection is HTTP layer (ADR-001), not in scope. |
| FR-5  | out-of-scope | n/a | Retry orchestrator (ADR-003), not in scope. |
| FR-6  | out-of-scope | n/a | Backoff/jitter (ADR-003), not in scope. |
| FR-7  | met | `src/token-bucket.ts:103-132`; `src/token-bucket.ts:146-153`; `tests/token-bucket.test.ts:40-53`, `75-86`, `90-105`, `134-143` | `tryAcquire` is synchronous (no `await`/`Promise`/`setTimeout` — verified by `grep -E "(setInterval\|setTimeout\|await\|Promise\|Date\.now\|queue\|buffer)" src/token-bucket.ts` returning only doc-comment hits at lines 10/13/43/55/58, never code). The reject path returns `{ ok: false, retryAfterMs }` immediately; `retryAfterMs` is the ms-precision wait used as `X-RateLimit-Reset-Ms`, and `computeRetryAfterSeconds` (line 146) implements the whole-second `Retry-After` with min=1, defensively coercing 0/NaN/negative inputs to 1 (line 147). Header emission itself is the HTTP handler's job — that is not in this chunk. |
| FR-8  | out-of-scope | n/a | Body-size cap is HTTP layer, not in scope. |
| FR-9  | out-of-scope | n/a | Port-bind contract (ADR-007), not in scope. |
| FR-10 | out-of-scope | n/a | `X-Request-Id` header (ADR-005), not in scope. |
| FR-11 | out-of-scope | n/a | Pass-through is HTTP layer, not in scope. |
| FR-12 | out-of-scope | n/a | Method/path/Content-Type strictness is HTTP layer, not in scope. |

## Per-NFR check

| NFR-ID | Status | Evidence (file:line / metric / log) | Notes |
|--------|--------|--------------------------------------|-------|
| NFR-LAT-1 | out-of-scope | n/a | Wall-time guard lives in retry orchestrator + HTTP server, not in the bucket. |
| NFR-LAT-2 | out-of-scope | n/a | Per-attempt timeouts are undici (ADR-002), not in scope. |
| NFR-THR-1 | met | `src/token-bucket.ts:115-117`; `tests/token-bucket.test.ts:148-161` | The bucket sustains exactly 5 RPS in steady state — `tests/token-bucket.test.ts:148` advances the clock by 200 ms 50 times and asserts every acquire succeeds (10 simulated seconds, 50 successful acquires post-burst). Math at `src/token-bucket.ts:116` uses `(elapsedMs/1000)*rate` so 200 ms × 5/s = 1.0 token regenerated per cycle, which exactly matches the 1-token-per-tick spend. |
| NFR-CAP-1 | met | `src/token-bucket.ts:62-86`, `103-132`; `tests/token-bucket.test.ts:27-35`, `40-53`, `57-71`, `165-177` | Bucket starts full at `burst=5` (`src/token-bucket.ts:84`), refills lazily at `rate=5`/s with a `Math.min(this.burst, ...)` cap (`src/token-bucket.ts:116`), and fails the 6th immediate acquire (`tests/token-bucket.test.ts:40`). Burst cap verified: idling 10 s yields exactly 5 acquires not 50 (`tests/token-bucket.test.ts:165-177`). Process-wide single-instance assumption is the deploy ADR's responsibility, not the bucket's. |
| NFR-CAP-2 | not testable | n/a | Inbound traffic forecast is a planning baseline, not a code property. |
| NFR-AVL-1 | out-of-scope | n/a | Drain lifecycle (ADR-006), not in scope. |
| NFR-DUR-1 | met | `src/token-bucket.ts` (whole file) | Module is in-process state only: a single `tokens: number` and `lastRefill: bigint` (lines 66-67). No filesystem, no DB, no journal. `grep -E "(fs\|readFile\|writeFile\|require\|import)" src/token-bucket.ts` finds zero I/O imports. |
| NFR-SEC-1 | out-of-scope | n/a | Logging/secret handling lives in observability stack (ADR-005). The bucket logs nothing; constructor inputs are numeric `rate`/`burst` only — no secret material can flow through. |
| NFR-SEC-2 | out-of-scope | n/a | Threat model is system-wide, not bucket-local. |
| NFR-OBS-1 | out-of-scope | n/a | Logging + metrics live in ADR-005; the bucket's `outcome=rate_limited` integration is the HTTP handler's job and is explicitly out of scope per `src/token-bucket.ts:1-13`. |
| NFR-DEP-1 | met | `package.json:15-19` | Zero runtime dependencies (`devDependencies` only: `@types/node`, `typescript`, `vitest`). No `dependencies` field present. Runtime constraint `node >=20 <23` (`package.json:7-9`) covers v20 + v22 LTS per spec line 104. |
| NFR-DEP-2 | out-of-scope | n/a | Container topology, not in scope. |

## Per-ADR check

| ADR-ID | Status | Evidence (file:line) | Deviation reason (if any) |
|--------|--------|----------------------|----------------------------|
| ADR-001 | out-of-scope | n/a | Fastify HTTP surface is a separate chunk. |
| ADR-002 | out-of-scope | n/a | undici upstream client is a separate chunk. |
| ADR-003 | out-of-scope | n/a | Retry orchestrator is a separate chunk. |
| ADR-004 | implemented | `src/token-bucket.ts:62-132` (algorithm), `src/token-bucket.ts:146-153` (whole-second header), `tests/token-bucket.test.ts:1-198` (11 tests citing ADR-004 step IDs by comment) | All five ADR-004 algorithm steps land at code lines: step 1 = `src/token-bucket.ts:105`, step 2 = `:111-112`, step 3 = `:115-117`, step 4 = `:121-124`, step 5 = `:129-131`. Constructor signature matches the ADR's quoted `class TokenBucket { rate, burst, clock = process.hrtime.bigint }` shape (`src/token-bucket.ts:69-86`). Default clock is `process.hrtime.bigint` (`:81`) — the monotonic-clock choice the ADR mandates. Out-of-scope reservation: arch-review's only objection to ADR-004 was an absent `proxy_ratelimit_tokens_available` gauge, which is metrics integration and explicitly deferred per the chunk's scope statement. |
| ADR-005 | out-of-scope | n/a | Logging/metrics stack is a separate chunk. |
| ADR-006 | out-of-scope | n/a | Shutdown lifecycle is a separate chunk. |
| ADR-007 | out-of-scope | n/a | Deploy topology is a separate chunk. |

## Findings

> Severity: **critical** (ship-blocker) / **high** (fix this sprint) / **medium** / **low**.

### Finding 1

- **Severity**: low
- **Category**: undocumented behaviour / robustness gap (not a spec violation)
- **Evidence**: `src/token-bucket.ts:115-118` —
  ```ts
  if (elapsedMs > 0) {
    this.tokens = Math.min(this.burst, this.tokens + (elapsedMs / 1000) * this.rate);
  }
  this.lastRefill = now;
  ```
- **Impact**: The refill is correctly guarded against `elapsedMs <= 0` (e.g. two
  `tryAcquire` calls at the same `now`, or a non-monotonic clock injected in
  tests) — but `lastRefill = now` is updated unconditionally on line 118. If a
  caller injected a *non-monotonic* clock that walked backwards, `lastRefill`
  would also walk backwards, and a subsequent forward step would refill from
  the *lower* anchor — quietly granting extra tokens. With the default
  `process.hrtime.bigint` this cannot happen (it is monotonic by Node contract);
  the failure mode requires a misbehaving injected clock. Worth a one-line
  defensive `if (now > this.lastRefill) this.lastRefill = now;` or a comment
  pinning the monotonicity contract on the injected clock parameter.
- **Suggested fix**: Document the monotonicity precondition on `TokenBucketOptions.clock`
  in the JSDoc at `src/token-bucket.ts:42-46`, or assert `now >= this.lastRefill`
  defensively before mutating `lastRefill`.

### Finding 2

- **Severity**: low
- **Category**: missing test coverage (defensive-input gap)
- **Evidence**: `tests/token-bucket.test.ts:192-197` —
  ```ts
  expect(() => new TokenBucket({ rate: 0, burst: 5 })).toThrow();
  expect(() => new TokenBucket({ rate: -1, burst: 5 })).toThrow();
  expect(() => new TokenBucket({ rate: 5, burst: 0 })).toThrow();
  expect(() => new TokenBucket({ rate: 5, burst: -3 })).toThrow();
  ```
- **Impact**: The constructor's `Number.isFinite` check at `src/token-bucket.ts:72,75`
  rejects `NaN` and `Infinity`, but no test exercises those branches. A future
  refactor that swaps `Number.isFinite` for `>= 0` (or for a truthy check) would
  silently allow `NaN` / `Infinity` and the test suite would still pass. Same
  story for `computeRetryAfterSeconds` at `src/token-bucket.ts:147` — the `NaN`
  guard is not behaviourally tested.
- **Suggested fix**: Add `expect(() => new TokenBucket({ rate: NaN, burst: 5 })).toThrow();`
  and `expect(() => new TokenBucket({ rate: Infinity, burst: 5 })).toThrow();`
  alongside the existing defensive cases; add `expect(computeRetryAfterSeconds(NaN)).toBe(1);`
  to the `computeRetryAfterSeconds` test at `tests/token-bucket.test.ts:90-105`.

### Finding 3

- **Severity**: low
- **Category**: test discipline (vacuous assertion in default-clock test)
- **Evidence**: `tests/token-bucket.test.ts:183-187` —
  ```ts
  it("works with the default monotonic clock (ADR-004 process.hrtime.bigint)", () => {
    const bucket = new TokenBucket({ rate: 5, burst: 5 });
    const r = bucket.tryAcquire();
    expect(r.ok).toBe(true); // First token of a fresh bucket.
  });
  ```
- **Impact**: This test exercises the default-clock branch at `src/token-bucket.ts:81`
  but its only assertion (`r.ok === true` on a fresh bucket) is satisfied by the
  initial-burst behaviour and does not actually verify monotonicity or that the
  clock is hrtime rather than `Date.now`. The test's title promises more than
  the assertion delivers. The branch *is* covered for "constructor does not
  throw and first acquire works", which is non-trivial (it confirms that
  passing `process.hrtime.bigint` as a bare function reference works without a
  `this` binding — verified empirically with `node -e "const c = process.hrtime.bigint; c();"`),
  but the test title overpromises.
- **Suggested fix**: Either retitle to "first acquire on a fresh bucket succeeds
  under the default clock" (truth in advertising), or strengthen by draining the
  bucket and asserting that *after a real-time advance* the bucket refills
  (using an `async` test with a small `setTimeout(10)` and a tolerance).

### Finding 4

- **Severity**: low
- **Category**: missing test for the `lastRefill` advance on the reject path
- **Evidence**: ADR-004 step 5 (`process/deepseek-client/adr/004-outbound-rate-limit.md:99-103`)
  mandates "set `lastRefill = now` (so subsequent refill math is consistent)"
  on the reject path, implemented at `src/token-bucket.ts:118` (set
  unconditionally). No test asserts that two consecutive rejections at
  different clock instants compute a *decreasing* `retryAfterMs` (i.e. the
  second call sees the time already accumulated against the previous reject).
- **Impact**: A regression that moved the `lastRefill = now` assignment inside
  the `ok` branch (at `:122-123`) — semantically plausible "only update on
  success" — would break long-run rate-limit accuracy under sustained
  overflow but no current test would fail. The fractional-refill test at
  `tests/token-bucket.test.ts:111-130` advances the clock once per step and
  succeeds because `elapsedMs > 0` triggers the refill block; it does not
  verify the *anchoring* on the reject path.
- **Suggested fix**: Add a test that drains the bucket, advances 100 ms, calls
  `tryAcquire` (expect reject with `retryAfterMs == 100`), advances another
  50 ms, calls `tryAcquire` again, and asserts the second `retryAfterMs == 50`
  (proving `lastRefill` was advanced on the first reject).

## Verdict

- **Verdict**: ship
- **Justification**: All in-scope requirements are met with file:line evidence
  (FR-7 met at `src/token-bucket.ts:103-132,146-153`; NFR-CAP-1 + NFR-THR-1 met
  at `src/token-bucket.ts:115-117` plus tests `:148-161,165-177`; NFR-DEP-1 met
  at `package.json:15-19`; ADR-004 implemented across all five algorithm steps
  at `src/token-bucket.ts:103-132`). The code is structurally correct: there is
  no `await`, no `setTimeout`, no `setInterval`, no I/O, no `Date.now` —
  verified by direct grep, with all hits residing in doc-comments only. The
  default clock is `process.hrtime.bigint` (`src/token-bucket.ts:81`),
  satisfying the ADR's monotonicity choice. The 11 tests run in 3 ms,
  TypeScript strict-mode typecheck (`tsc --noEmit`) passes with zero errors
  (verified with `tsc --noEmit; EXIT=0`), and the test suite passes 11/11
  (verified with `vitest run` — output: `Test Files  1 passed (1) | Tests  11
  passed (11)`). The four findings (all `low`) are robustness/test-discipline
  improvements rather than spec violations: Finding 1 (defensive monotonicity
  contract), Finding 2 (NaN/Infinity branches not exercised), Finding 3
  (vacuous assertion in default-clock test), Finding 4 (no regression test for
  `lastRefill` advance on reject). None of them block ship; together they
  recommend a follow-up tightening pass before this module is wired into the
  HTTP handler. The arch-reviewer's only ADR-004 reservation
  (`proxy_ratelimit_tokens_available` gauge) is correctly deferred — it is a
  metrics-integration concern outside the scope of this minimal algorithm
  chunk, and the chunk's own scope statement at `src/token-bucket.ts:1-13`
  declares this explicitly.
