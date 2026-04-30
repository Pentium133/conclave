# ADR-007: Hand-rolled env-var validation, distroless Node 22 image, single-instance via host-port mapping

## Status

proposed

## Context

This ADR consolidates the configuration surface (which env vars exist, which
are required, how they are validated, when the proxy refuses to start) with
the runtime topology (base image, PID 1, non-root user, single-instance
enforcement, deploy procedure). The two are intertwined: the deploy contract
mandates env-only configuration (NFR-DEP-2), no config files, no secrets
manager. The boot-time validation is the proxy's only chance to refuse a
misconfigured environment loudly (FR-12 TLS, FR-9 port-bind-or-die,
NFR-DEP-1 required `DEEPSEEK_API_KEY`).

The single-instance enforcement story is the spec's most fragile invariant:
NFR-CAP-1 is per-process, FR-9 is bind-or-die, but spec-review objection 3
exposed that *rolling deploys* trivially break "single instance" for ~30 s
unless the operator follows the stop-then-start procedure rigorously. This
ADR pins the deploy contract that prevents that race.

This ADR **resolves spec-review objection 3** (single-instance enforcement
via stop-then-start procedure + host-port mapping + bind-or-die), the TLS
sub-clause of **objection 9** (`NODE_TLS_REJECT_UNAUTHORIZED` refuse-to-start),
and **objection 12** (memory bound is implicit from FR-8 + NFR-CAP-1; we
record the recommended container memory limit and Node heap flag here).

- Drives: NFR-DEP-1, NFR-DEP-2, FR-9, FR-12 (TLS sub-clause), NFR-SEC-1
  (key delivery), NFR-CAP-1 (per-process bucket precondition).
- Resolves: spec-review objection 3 (single-instance enforcement).
- Resolves: spec-review objection 9 sub-item TLS.
- Resolves: spec-review objection 12 (memory bound + heap flag).

## Alternatives

### Alternative A — Configuration: hand-rolled validator in a single `config.ts` module that throws on boot if any required var is absent or any rule is violated

- **Cost**: ~80 LOC. Zero new dependencies.
- **Complexity**: One module, one exported `loadConfig()` that returns a
  frozen object. Rules are explicit `if`/`throw` lines, easy to grep.
- **Correctness**: Each rule maps directly onto a spec clause. The most
  load-bearing rules are: `DEEPSEEK_API_KEY` non-empty (NFR-DEP-1);
  `NODE_TLS_REJECT_UNAUTHORIZED !== '0' && !== 'false'` (FR-12);
  `PORT` and `METRICS_PORT` parse to integers in `1..65535` and are not equal
  to each other (FR-9); `DEEPSEEK_BASE_URL` parses as a `https://` URL or
  defaults to `https://api.deepseek.com`. Exit non-zero with a one-line
  message naming the offending env var.
- **Operability**: Errors are bash-friendly (`exit 1` + stderr message),
  surface in `docker logs` immediately.
- **Verdict**: chosen — small enough to own, mapped 1-to-1 to spec.

### Alternative A — Configuration alt: `envalid` or `zod`-backed schema validation

- **Cost**: One more dep (`envalid` is small; `zod` is larger).
- **Complexity**: Moderate. The schema is declarative; the error messages
  are more uniform.
- **Correctness**: Equivalent to hand-rolled. The TLS-refuse-to-start rule
  is *not* a schema-level check (it's a forbidden-value rule on a Node
  global), so we still write it by hand.
- **Operability**: One more upgrade path; library error formatting is
  opinionated.
- **Verdict**: rejected — payoff for 80 LOC of validator is too small to
  justify the dependency, especially since the TLS rule must be hand-written
  anyway.

### Alternative B — Base image: `gcr.io/distroless/nodejs22-debian12`, non-root user, no shell

- **Cost**: Image is ~120 MiB; no shell to debug live (operators must
  `docker exec` a sidecar or use `kubectl debug` equivalents — out of scope
  here).
- **Complexity**: Distroless does not include `tini` and runs Node as PID 1.
  Node since 16 handles SIGTERM correctly as PID 1, so signal forwarding to
  ADR-006's drain handler works. No `apt-get`, no `apk`, smallest CVE
  surface.
- **Correctness**: Smaller attack surface; runs as `nonroot` (UID 65532) by
  default; nothing to chmod.
- **Operability**: No shell means cargo-cult `docker exec sh` debugging is
  blocked — operators are pushed toward proper observability (ADR-005).
- **Verdict**: chosen — best CVE / size / signal-handling combination
  among the options.

### Alternative B — Base image alt: `node:22-alpine` (musl libc)

- **Cost**: ~50 MiB.
- **Complexity**: Alpine includes a shell and apk; PID 1 is `node` — same
  signal handling story as distroless, so `tini` is unnecessary either way.
- **Correctness**: Alpine uses musl libc, which has historically caused
  subtle Node performance / DNS behaviour differences vs glibc. For an HTTP
  client doing DNS lookups against `api.deepseek.com`, musl's resolver is
  not a place we want to live.
- **Operability**: Smaller image; shell present, which is a debugging
  convenience and a CVE / supply-chain expansion at once.
- **Verdict**: rejected — musl DNS quirks are exactly the wrong risk for an
  HTTP client; CVE surface is larger; debugging convenience is offset by
  ADR-005 observability.

### Alternative B — Base image alt: `node:22-slim` (Debian-based, glibc)

- **Cost**: ~140 MiB.
- **Complexity**: Standard Debian Node image. Includes `apt`, glibc, a shell.
- **Correctness**: glibc DNS, no musl gotchas. Larger CVE surface than
  distroless (apt is on-image).
- **Operability**: Maximum debugging convenience.
- **Verdict**: rejected — distroless dominates on CVE / size for a
  production proxy where we are not encouraging exec-debugging.

### Alternative C — Single-instance enforcement: deploy procedure (stop-then-start) + host-port mapping, no in-process leader election

- **Cost**: Zero proxy LOC; the entire mechanism is operator runbook + Docker
  Compose configuration.
- **Complexity**: Operator follows NFR-DEP-2's procedure verbatim. FR-9
  bind-or-die is the second line of defence (a second container attempting
  the same host-port mapping fails immediately).
- **Correctness**: Adequate when followed. Spec-review objection 3 named the
  failure mode: a default `docker compose up -d` overlaps containers for ~30 s.
  The fix (in NFR-DEP-2 prose) is **mandatory stop-then-start** — `docker
  compose stop` + `docker compose wait` + `docker compose up -d` — which
  guarantees no overlap. We also adopt the host-port mapping so any
  accidental second container fails on bind.
- **Operability**: One additional runbook step. Verifiable
  (`docker compose ps` shows zero containers between `stop` and `up`).
- **Verdict**: chosen — the failure mode is a procedure problem, the fix
  is procedural; in-process leader election (file lock, etcd, etc.) would
  be massive overkill for a single-host single-replica service.

### Alternative C — Single-instance alt: in-process advisory file lock on a host-mounted volume

- **Cost**: ~20 LOC; requires a host volume mount.
- **Complexity**: `flock(2)` on Linux works in-container if the lockfile is
  on a host-mounted path. Adds a deployment-time requirement.
- **Correctness**: Defends against operator error (rolling restart starts
  second container before first releases the lock) at the cost of a fragile
  cleanup path (lock survives a SIGKILL'd container until the kernel frees
  it on host reboot or `lsof | xargs flock -u`).
- **Operability**: New failure mode: lockfile orphaned, every subsequent
  start fails until manual cleanup. Operator confusion at 3am.
- **Verdict**: rejected — replaces "operator follows runbook" with "operator
  cleans up stale locks at 3am". Net negative.

## Decision

**Configuration surface** (Alternative A — Configuration). One module
`config.ts` validates and freezes:

| Variable                       | Required | Default                       | Rule                                              |
|--------------------------------|----------|-------------------------------|---------------------------------------------------|
| `DEEPSEEK_API_KEY`             | yes      | —                             | non-empty string; never logged (NFR-SEC-1)        |
| `DEEPSEEK_BASE_URL`            | no       | `https://api.deepseek.com`    | parses as `https://` URL                          |
| `PORT`                         | no       | `8080`                        | integer in `1..65535`, ≠ `METRICS_PORT`           |
| `METRICS_PORT`                 | no       | `9090`                        | integer in `1..65535`, ≠ `PORT`                   |
| `LOG_LEVEL`                    | no       | `info`                        | one of `trace`/`debug`/`info`/`warn`/`error`/`fatal` |
| `BUILD_VERSION`                | no       | `0.0.0`                       | string; surfaced as `proxy_build_info{version}`   |
| `BUILD_GIT_SHA`                | no       | `unknown`                     | string; surfaced as `proxy_build_info{git_sha}`   |
| `NODE_TLS_REJECT_UNAUTHORIZED` | no       | unset                         | MUST NOT equal `0` or `false`; refuse-to-start    |

Boot-time validation runs **before** Fastify is initialised. On any
violation, log a single ERROR line naming the variable and `process.exit(1)`.
This satisfies the FR-9 bind-or-die spirit at the configuration layer too:
config errors are loud, not silent.

**Build / image** (Alternative B). Dockerfile shape:

```Dockerfile
FROM node:22-bookworm AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
RUN npm run build           # emits ./dist

FROM gcr.io/distroless/nodejs22-debian12 AS runtime
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER nonroot
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=384"
EXPOSE 8080 9090
CMD ["dist/server.js"]
```

Node 22 distroless, non-root, `--max-old-space-size=384` (memory floor for
spec-review objection 12: with FR-8 256 KiB body cap × NFR-CAP-1 5 RPS
worst-case in-flight, peak buffering is well under 100 MiB; 384 MiB Node
heap leaves ~128 MiB for the container's own RSS within a 512 MiB cgroup
limit).

**Single-instance enforcement** (Alternative C). NFR-DEP-2's deploy
procedure is the primary mechanism:

```yaml
services:
  deepseek-client:
    image: deepseek-client:${BUILD_VERSION}
    restart: unless-stopped
    stop_signal: SIGTERM
    stop_grace_period: 30s          # ADR-006 contract
    mem_limit: 512m                 # objection 12
    ports:
      - "8080:8080"                 # host-port mapping = secondary single-instance defence
      - "9090:9090"                 # metrics on host network for operator scrape
    environment:
      DEEPSEEK_API_KEY: ${DEEPSEEK_API_KEY}
      # PORT, METRICS_PORT, LOG_LEVEL, DEEPSEEK_BASE_URL: defaulted
```

Mandatory deploy steps (operator runbook):

1. `docker compose pull`
2. `docker compose stop && docker compose wait deepseek-client`
3. `docker compose up -d`
4. `curl -sf http://localhost:9090/metrics | grep '^proxy_up 1'`

Step 2 is the load-bearing one: `wait` blocks until the container fully
exits (drain complete + ADR-006's `process.exit(0)`). Steps 1, 3, 4 are
plumbing. **`docker compose up -d` without a prior `stop`** would
re-create the container while the old is still running for a few seconds,
producing exactly the spec-review objection 3 race; the runbook forbids
this.

This **resolves spec-review objection 3**: the procedure makes overlap
impossible, the host-port mapping makes accidental overlap fail loudly, and
FR-9 bind-or-die makes the failure immediate and observable.

It **resolves spec-review objection 9 (TLS sub-clause)**: the boot-time
check on `NODE_TLS_REJECT_UNAUTHORIZED` exits non-zero with a clear error
before any port is bound; FR-12's TLS-refuse-to-start contract is
implementable in 5 lines of `config.ts`.

It **resolves spec-review objection 12**: the `mem_limit: 512m` plus
`--max-old-space-size=384` plus FR-8 256 KiB body cap together bound RSS
well below the OOM threshold under any forecast or stress scenario.

## Consequences

### Positive

- One config module, all rules in one place, all errors fail-fast at boot.
- Distroless image: minimal CVE surface, no shell to encourage live-debug
  shortcuts, glibc-based DNS so undici / Node DNS works as expected.
- Stop-then-start deploy procedure plus host-port mapping plus bind-or-die
  is a triple-layer defence against the most realistic single-instance
  failure (rolling deploy overlap).
- Memory is bounded by construction: container limit + Node heap + body cap
  cannot exceed the cgroup. OOM-kill is now a known-impossible failure for
  the forecast load.
- TLS refuse-to-start guards a footgun (`NODE_TLS_REJECT_UNAUTHORIZED=0`
  for a local mock leaking into prod).

### Negative

- The deploy procedure is **operator-runnable correctness**, not enforced
  by code. An operator who runs `docker compose up -d` without the prior
  `stop` ships an objection-3 violation. Mitigation: documented runbook,
  CI-side deploy script, possibly a future iteration with a deploy-script
  wrapper. Today, runbook discipline is part of the trust boundary.
- 30 s `stop_grace_period` doubles the deploy duration vs the Docker
  default. Acceptable per NFR-AVL-1's best-effort SLA.
- Distroless image has no shell: live debugging requires a sidecar or
  rebuilt image. Operators trained on `docker exec sh` will protest. We
  accept this; ADR-005's observability is the substitute.
- Hand-rolled config validator means we own every rule's error message;
  a future variable added without a corresponding rule silently defaults.
  Mitigation: a unit test that loads `config.ts` with an empty env and
  asserts every required variable raises a named error.
- 512 MiB cgroup + 384 MiB heap is a **recommended** number, not a
  spec-mandated one. NFR-DEP-2 explicitly says these limits are
  operator-set; we provide a sane default in the compose template and
  flag it as a starting point.

## Open questions

- Should the deploy procedure be encoded as a `Makefile` / `justfile`
  target shipped in the repo, so the operator runs `just deploy` and the
  script enforces the stop-then-wait-then-up sequence? The arch-reviewer
  may push for this. We currently leave it as a runbook + compose
  template; tooling is a follow-up.
- `mem_limit` and `--max-old-space-size` are sized for NFR-CAP-2 forecast
  (< 3 RPS peak). If the forecast is wrong by 10× the limits will need
  to be raised; flagged for a future iteration.
- Should `BUILD_VERSION` and `BUILD_GIT_SHA` be embedded at build time
  (baked into the image via `ARG` / `ENV` in the Dockerfile) instead of
  passed in at runtime? Build-time embedding is more tamper-resistant
  but couples the image to the version tag. We choose runtime env for
  simplicity; the arch-reviewer may push to embed.
