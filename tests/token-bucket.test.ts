// Tests for the outbound token bucket.
// Spec refs: NFR-CAP-1 (5 RPS, burst 5), FR-7 (immediate-rejection 429 with
// Retry-After whole-seconds + X-RateLimit-Reset-Ms millis-precision).
// ADR ref: adr/004-outbound-rate-limit.md (lazy fractional refill, injectable
// monotonic clock, no internal queue, no setTimeout, no I/O).

import { describe, it, expect } from "vitest";
import { TokenBucket, computeRetryAfterSeconds } from "../src/token-bucket.js";

/** Test helper: a controllable monotonic bigint clock measured in nanoseconds. */
function makeClock(startNs: bigint = 0n): {
  now: () => bigint;
  advanceMs: (ms: number) => void;
} {
  let nowNs = startNs;
  return {
    now: () => nowNs,
    advanceMs: (ms: number) => {
      nowNs += BigInt(Math.round(ms * 1e6));
    },
  };
}

describe("TokenBucket — NFR-CAP-1, FR-7, ADR-004", () => {
  // NFR-CAP-1: bucket starts full at burst=5 so the first 5 acquires must succeed
  // without any time advance.
  it("starts with a full bucket of size=burst (NFR-CAP-1, ADR-004 step 4)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });

    for (let i = 0; i < 5; i++) {
      const r = bucket.tryAcquire();
      expect(r.ok, `acquire #${i + 1} should succeed`).toBe(true);
    }
  });

  // NFR-CAP-1: 6th consecutive acquire (no time advance) must be rejected because
  // the bucket has been drained from 5 → 0 by the previous 5 acquires.
  // FR-7: rejection must be immediate; the result carries retryAfterMs.
  it("rejects the 6th acquire when the bucket is empty (FR-7 immediate-rejection)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    for (let i = 0; i < 5; i++) bucket.tryAcquire();

    const r = bucket.tryAcquire();
    expect(r.ok).toBe(false);
    if (!r.ok) {
      // At rate=5/s, refilling 1 full token takes 200 ms.
      // After 5 immediate acquires the bucket holds 0 tokens, so retryAfterMs ≈ 200 ms.
      expect(r.retryAfterMs).toBeGreaterThan(0);
      expect(r.retryAfterMs).toBeLessThanOrEqual(200);
    }
  });

  // ADR-004 step 3: lazy fractional refill — after time passes, the bucket
  // refills at `rate * elapsedMs/1000` and is capped at `burst`.
  it("refills tokens after time advance up to burst capacity (ADR-004 step 3)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    // Drain the bucket.
    for (let i = 0; i < 5; i++) bucket.tryAcquire();
    expect(bucket.tryAcquire().ok).toBe(false);

    // Advance 1 full second → 5 tokens regenerated → 5 acquires must succeed.
    clock.advanceMs(1000);
    for (let i = 0; i < 5; i++) {
      expect(bucket.tryAcquire().ok, `post-refill acquire #${i + 1}`).toBe(true);
    }
    // 6th must fail again (bucket is at most `burst`, never above).
    expect(bucket.tryAcquire().ok).toBe(false);
  });

  // FR-7: on overflow, retryAfterMs must be the millis until the next whole token.
  // With rate=5/s an empty bucket recovers 1 token in exactly 200 ms.
  it("computes retryAfterMs as ms-until-next-whole-token on overflow (FR-7, ADR-004 step 5)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    for (let i = 0; i < 5; i++) bucket.tryAcquire();

    const r = bucket.tryAcquire();
    expect(r.ok).toBe(false);
    if (!r.ok) {
      // Empty bucket → 1/5 s = 200 ms wait. ceil() may push a smidge above 200.
      expect(r.retryAfterMs).toBe(200);
    }
  });

  // FR-7: Retry-After (whole seconds) is rounded up with a 1-second minimum.
  // ADR-004: Retry-After = ceil(retryAfterMs / 1000), min 1.
  it("rounds Retry-After header up to whole seconds with min=1 (FR-7, ADR-004)", () => {
    // 200 ms → 1 s (ceil + floor)
    expect(computeRetryAfterSeconds(200)).toBe(1);
    // 1 ms → 1 s (floor)
    expect(computeRetryAfterSeconds(1)).toBe(1);
    // 0 ms → 1 s (defensive: Retry-After: 0 forbidden by FR-7 floor)
    expect(computeRetryAfterSeconds(0)).toBe(1);
    // 1000 ms → 1 s (no rounding needed)
    expect(computeRetryAfterSeconds(1000)).toBe(1);
    // 1001 ms → 2 s (ceil)
    expect(computeRetryAfterSeconds(1001)).toBe(2);
    // 1999 ms → 2 s
    expect(computeRetryAfterSeconds(1999)).toBe(2);
    // 5000 ms → 5 s
    expect(computeRetryAfterSeconds(5000)).toBe(5);
  });

  // ADR-004 step 3: fractional refill — after a partial time advance the bucket
  // holds a non-integer number of tokens; tryAcquire succeeds only when
  // tokens >= 1, and the next overflow's retryAfterMs reflects the fraction
  // already accumulated.
  it("handles fractional-token refill (ADR-004 step 3 — fractional on purpose)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    // Drain
    for (let i = 0; i < 5; i++) bucket.tryAcquire();
    expect(bucket.tryAcquire().ok).toBe(false);

    // Advance 100 ms → 0.5 tokens. Still not enough for an acquire.
    clock.advanceMs(100);
    const partial = bucket.tryAcquire();
    expect(partial.ok).toBe(false);
    if (!partial.ok) {
      // Need 0.5 more tokens → another 100 ms.
      expect(partial.retryAfterMs).toBe(100);
    }

    // Advance another 100 ms → 1.0 token, acquire succeeds.
    clock.advanceMs(100);
    expect(bucket.tryAcquire().ok).toBe(true);
  });

  // FR-7: rejection path must be immediate — verified structurally by the
  // synchronous shape of tryAcquire: the call returns a value, never a Promise.
  it("tryAcquire is synchronous — no await, no Promise (FR-7 immediate-rejection structural invariant)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    for (let i = 0; i < 5; i++) bucket.tryAcquire();

    const result = bucket.tryAcquire();
    // If tryAcquire ever became async, this would be a Promise instead of a record.
    expect(result).not.toBeInstanceOf(Promise);
    expect(typeof (result as { ok: boolean }).ok).toBe("boolean");
  });

  // Steady-state correctness: at exactly the rated load (1 request every 200 ms)
  // the bucket should sustain indefinitely without rejection (after the initial
  // burst is drained or not).
  it("sustains the steady-state rate (5 RPS one-every-200ms) without rejection (NFR-CAP-1, NFR-THR-1)", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    // Drain initial burst.
    for (let i = 0; i < 5; i++) {
      expect(bucket.tryAcquire().ok).toBe(true);
    }
    // Now hammer at exactly 5 RPS for 50 cycles (10 simulated seconds).
    for (let i = 0; i < 50; i++) {
      clock.advanceMs(200);
      const r = bucket.tryAcquire();
      expect(r.ok, `steady-state acquire #${i + 1}`).toBe(true);
    }
  });

  // Burst correctness: idle for 10 s, then 5 immediate acquires must succeed
  // (bucket capped at burst=5, not unbounded).
  it("caps refilled tokens at burst (idle 10s then 5 acquires, not 50) — ADR-004 step 3 cap", () => {
    const clock = makeClock();
    const bucket = new TokenBucket({ rate: 5, burst: 5, clock: clock.now });
    // Drain
    for (let i = 0; i < 5; i++) bucket.tryAcquire();
    // Idle 10 seconds — naïve math says 50 tokens but the cap is burst=5.
    clock.advanceMs(10_000);
    for (let i = 0; i < 5; i++) {
      expect(bucket.tryAcquire().ok, `post-idle burst #${i + 1}`).toBe(true);
    }
    // 6th must fail — the cap held.
    expect(bucket.tryAcquire().ok).toBe(false);
  });

  // ADR-004 explicit: monotonic clock injection for deterministic tests.
  // This test exercises the default-clock branch (no clock argument). The default
  // is process.hrtime.bigint, which is monotonic. We just check it returns a
  // sane shape; we cannot assert timing cheaply without sleeps.
  it("works with the default monotonic clock (ADR-004 process.hrtime.bigint)", () => {
    const bucket = new TokenBucket({ rate: 5, burst: 5 });
    const r = bucket.tryAcquire();
    expect(r.ok).toBe(true); // First token of a fresh bucket.
  });

  // Defensive constructor invariants. The spec pins rate=5, burst=5, but the
  // module accepts the parameters; bad inputs should throw rather than corrupt
  // state silently.
  it("rejects non-positive rate / burst at construction (defensive)", () => {
    expect(() => new TokenBucket({ rate: 0, burst: 5 })).toThrow();
    expect(() => new TokenBucket({ rate: -1, burst: 5 })).toThrow();
    expect(() => new TokenBucket({ rate: 5, burst: 0 })).toThrow();
    expect(() => new TokenBucket({ rate: 5, burst: -3 })).toThrow();
  });
});
