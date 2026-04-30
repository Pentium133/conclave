// Outbound token-bucket rate limiter for the deepseek-client proxy.
//
// Scope of this chunk: the algorithm only. No Fastify integration, no headers
// emission, no metrics, no logging. The HTTP handler that wraps this bucket
// (FR-7 rejection response, NFR-OBS-1 outcome=rate_limited) lives in a
// different module and is out of scope here.
//
// Spec refs: NFR-CAP-1 (process-wide token bucket, 5 RPS, burst 5),
// FR-7 (immediate-rejection 429 with Retry-After whole-seconds + minimum 1s,
// X-RateLimit-Reset-Ms millisecond-precision; no internal queue/buffer/delay).
// ADR ref: per adr/004-outbound-rate-limit.md (Alternative A: hand-rolled,
// lazy fractional refill, injectable monotonic clock, single-thread JS
// serialisation, no setInterval).

/** Successful acquisition: a token was consumed. */
export interface AcquireOk {
  readonly ok: true;
}

/**
 * Rejected acquisition: bucket was empty. Caller must respond immediately
 * (FR-7) with HTTP 429 and headers derived from `retryAfterMs`.
 *
 * `retryAfterMs` is the millisecond-precision wait until the next whole token
 * becomes available, drawn from the same monotonic clock the bucket uses for
 * refill. Per ADR-004 this maps directly to `X-RateLimit-Reset-Ms`; the
 * whole-second `Retry-After` header is `computeRetryAfterSeconds(retryAfterMs)`.
 */
export interface AcquireReject {
  readonly ok: false;
  readonly retryAfterMs: number;
}

export type AcquireResult = AcquireOk | AcquireReject;

export interface TokenBucketOptions {
  /** Steady-state refill rate in tokens per second. NFR-CAP-1: 5. */
  readonly rate: number;
  /** Burst capacity (also the initial number of tokens). NFR-CAP-1: 5. */
  readonly burst: number;
  /**
   * Monotonic clock returning a bigint number of nanoseconds. Defaults to
   * `process.hrtime.bigint`. Per ADR-004 we prefer hrtime over Date.now to
   * defend against NTP step on container hosts; the spec only needs forward
   * progress, not absolute time.
   */
  readonly clock?: () => bigint;
}

/**
 * In-process token bucket with lazy fractional refill.
 *
 * Per ADR-004:
 *   - Single-threaded JS serialises all callbacks; no concurrency primitives.
 *   - Refill is computed on read (no setInterval, no event-loop drift).
 *   - Fractional tokens are intentional: we serve a request as soon as
 *     `tokens >= 1`, not only on quantised 200-ms boundaries.
 *   - `tryAcquire` is synchronous: no `await`, no `setTimeout`, no I/O.
 *     This makes FR-7 immediate-rejection a structural invariant of the
 *     module, not a runtime check.
 */
export class TokenBucket {
  private readonly rate: number;
  private readonly burst: number;
  private readonly clock: () => bigint;
  private tokens: number;
  private lastRefill: bigint;

  constructor(options: TokenBucketOptions) {
    // Defensive: NFR-CAP-1 pins rate=5, burst=5, but we still validate to
    // catch refactors that accidentally zero the parameters.
    if (!Number.isFinite(options.rate) || options.rate <= 0) {
      throw new RangeError(`rate must be a positive finite number, got ${options.rate}`);
    }
    if (!Number.isFinite(options.burst) || options.burst <= 0) {
      throw new RangeError(`burst must be a positive finite number, got ${options.burst}`);
    }
    this.rate = options.rate;
    this.burst = options.burst;
    // ADR-004: prefer process.hrtime.bigint() — monotonic, unaffected by NTP step.
    this.clock = options.clock ?? process.hrtime.bigint;
    // ADR-004: bucket starts full at burst capacity. The first `burst`
    // acquires after construction succeed without any time advance.
    this.tokens = this.burst;
    this.lastRefill = this.clock();
  }

  /**
   * Attempt to consume one token.
   *
   * Per ADR-004 step-by-step:
   *   1. Read `now` from the monotonic clock.
   *   2. Compute elapsed ms since last refill.
   *   3. Refill: tokens = min(burst, tokens + elapsedMs/1000 * rate).
   *   4. If tokens >= 1: decrement, advance `lastRefill`, return ok.
   *   5. Else: compute retryAfterMs = ceil((1 - tokens) / rate * 1000),
   *      advance `lastRefill` so next refill math stays consistent, return reject.
   *
   * FR-7 invariant: this method is synchronous and does no I/O. Rejection is
   * immediate. The calling HTTP handler is responsible for writing the 429
   * response with `Retry-After` and `X-RateLimit-Reset-Ms` headers.
   */
  tryAcquire(): AcquireResult {
    // ADR-004 step 1.
    const now = this.clock();

    // ADR-004 step 2: bigint nanos → number ms. We divide before converting to
    // keep precision; `Number(bigint) / 1e6` would also work but the bigint
    // subtract first keeps the fractional-ms component lossless within the
    // double-precision range we care about (well under 2^53).
    const elapsedNs = now - this.lastRefill;
    const elapsedMs = Number(elapsedNs) / 1e6;

    // ADR-004 step 3: lazy fractional refill, capped at burst.
    if (elapsedMs > 0) {
      this.tokens = Math.min(this.burst, this.tokens + (elapsedMs / 1000) * this.rate);
    }
    this.lastRefill = now;

    // ADR-004 step 4.
    if (this.tokens >= 1) {
      this.tokens -= 1;
      return { ok: true };
    }

    // ADR-004 step 5: deficit / rate gives seconds until the next whole token;
    // ceil to ms keeps us from advising "0 ms" on the millisecond-precision
    // header. retryAfterMs is the wait the caller must observe.
    const deficitTokens = 1 - this.tokens;
    const retryAfterMs = Math.ceil((deficitTokens / this.rate) * 1000);
    return { ok: false, retryAfterMs };
  }
}

/**
 * Compute the `Retry-After` header value (whole seconds, minimum 1) from a
 * millisecond wait. Per FR-7 the proxy MUST emit `Retry-After: <integer
 * seconds, rounded up, minimum 1>`; per ADR-004 the floor of 1 is HTTP/1.1
 * spec compliance and is an acknowledged over-advise relative to the
 * millisecond-precision `X-RateLimit-Reset-Ms`.
 *
 * Exported for use by the HTTP handler that owns header emission, and tested
 * here so the rounding rule is pinned to the algorithm module rather than
 * the framework integration.
 */
export function computeRetryAfterSeconds(retryAfterMs: number): number {
  if (!Number.isFinite(retryAfterMs) || retryAfterMs <= 0) {
    // Defensive: FR-7 forbids Retry-After: 0; the floor of 1 always wins.
    return 1;
  }
  const seconds = Math.ceil(retryAfterMs / 1000);
  return Math.max(1, seconds);
}
