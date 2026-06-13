---
name: code-craft
description: Apply engineering standards when writing, refactoring, reviewing, auditing, or extending Python / Go / TypeScript / JavaScript / TSX code. Fires whenever such a file is created or edited, whenever a diff or PR is reviewed, and on "/review", "review this PR", "review the diff", "code review", "audit this", "fix the bug", "implement X", "add a feature", "refactor X", "make this faster", "make this safer", "add tests", "harden this", "is this production-ready". Also triggers on Bash `gh pr diff/view/create`, `git diff`, `git show`, and edits to `*.py`, `*.go`, `*.ts`, `*.tsx`, `*.js`, `*.jsx`. Covers TDD, modularity, performance, memory, resilience, security, observability, review-comment style, and the five mandatory dimensions (performance, modularity, concurrency, memory, scale). Stays active for the whole conversation once triggered — re-apply on every code-touching turn without waiting for a re-trigger.
---

# code-craft

Engineering principles for production-grade Python, Go, and TypeScript. Simplicity, correctness, performance, and maintainability over cleverness. These are non-negotiable defaults; deviate only on user instruction or when a principle genuinely doesn't apply (throwaway script).

## How to use this skill

**Mandatory first action — load the cross-cutting references.** Before producing ANY code, diff, review comment, or design opinion, read these. They are required for every code task, not "open when relevant." Skipping them = task incomplete.

```
references/engagement.md   — how to engage with the task before coding
references/tdd.md          — test-first workflow + integration patterns
references/resilience.md   — pools, timeouts, breakers, retries, degradation
references/security.md     — threat model, OWASP checklist, dep hygiene
references/performance.md  — measurement loop, profilers, percentiles, hot-path patterns
```

**Then read the language reference(s)** for whatever is in play — every relevant one for mixed-language tasks:

```
references/python.md       — any Python file
references/golang.md       — any Go file
references/typescript.md   — any TypeScript / JavaScript / TSX file
```

**Topic references — open on demand when the task touches the topic.** Same binding force as the rest of this skill once loaded.

```
references/distributed.md     — process boundaries: sagas, CDC, idempotency, fencing tokens, ordering, partial failure
references/concurrency.md     — channels vs locks, structured concurrency, backpressure, cancellation propagation
references/api-contracts.md   — REST/gRPC/protobuf versioning, breaking changes, OpenAPI, contract tests, webhooks
references/observability.md   — SLO/SLI, error budgets, RED/USE, multi-window burn-rate alerting
references/incident-response.md — live debugging, mitigation order, blast-radius limits, blameless postmortem
references/caching.md         — stampede protection (singleflight + XFetch), TTL jitter, invalidation, negative caching
references/feature-flags.md   — flag types, kill switches, gradual rollout, flag debt, fail-safe defaults
references/migrations.md      — expand → migrate → contract, online DDL, backfills, rollout compatibility
```

When to open which (rough mapping — open any that fit):

| Task touches… | Open |
|---|---|
| Queue consumer, retry, multi-service workflow, distributed lock, webhook | `distributed.md` |
| Goroutines / async tasks / channels / locks / worker pools | `concurrency.md` |
| Public API (REST / gRPC / proto / webhook / SDK) add or change | `api-contracts.md` |
| SLO design, alerting, dashboards, on-call surface | `observability.md` |
| On-call / postmortem / rollback design / kill-switch placement | `incident-response.md` |
| Any cache (in-process LRU, Redis, CDN) | `caching.md` |
| Any feature flag — new, change, removal | `feature-flags.md` |
| Any DDL or data backfill on a populated table | `migrations.md` |

Skip a topic reference only if the task doesn't touch it. References and this file are **one prompt** — a rule in a reference binds as hard as a rule here.

**Workflow once loaded:**

1. Detect the mode (greenfield / refactor / review).
2. Apply engagement principles before writing or commenting.
3. Apply core principles to the code.
4. Run every change through the review checklist as the final pass.
5. Run `scripts/lint.sh` and `scripts/test.sh` before declaring done.

**Persistence.** Once loaded, the skill stays active for every code-touching turn in the conversation — references in scope, checklist on every diff, five dimensions on every change. Off-switches: user says "stop applying code-craft" / "skip the review", or the task involves no code.

---

## Mode detection

Decide first — the discipline differs sharply.

**Greenfield** — "build", "create", "scaffold", "new", "from scratch", "implement X", "add an endpoint/service", "spin up", "set up", "design X" where X doesn't exist.

- Failing test first, watch it fail, then minimum code to pass.
- Small interface in front of every external dependency (DB, cache, queue, HTTP) so implementations swap at the edge.
- Pick resilience primitives upfront: pool, breaker, timeouts, retry policy.
- Threat-model before input / auth / secret handlers.
- No features, params, or abstractions beyond a current concrete need.

**Refactor** — "fix", "refactor", "update", "extend", "the bug is", "rename", "rewrite", "clean up", "tighten", "harden", "make this faster/safer", "add tests", "wire X into Y", "migrate A to B", or a reference to existing files.

- **In-path cleanup is required; off-path cleanup is mentioned, not made.** Bad name / magic number on a line you touch → fix. Smell in an unrelated file → mention, don't change.
- No new patterns or abstractions unless the change genuinely requires them.
- Preserve existing tests; if one fails, understand why before changing it. Add tests for the new behavior.
- Minimal diff — every changed line traces to the request or required in-path cleanup.

**Review** — "review this / this PR / the diff", "code review", "audit this", "PR feedback", `/review`, `gh pr diff/view`, `git diff` on someone else's change.

- Run every change through the **Review checklist**.
- One comment per issue in **Review-mode output style** (WHAT / WHY / FIX + severity).
- Skip pure-style nits unless they change meaning.

Ambiguous (e.g. "add an endpoint to the existing service") → new code is greenfield, surrounding code is refactor.

---

## Mandatory engineering dimensions

**Every code task MUST be examined across these five dimensions, even when the user doesn't name them.** Work that doesn't visibly engage each one is incomplete. Author preference: *"Please also tackle performance, modularity, concurrency, memory and scale issues necessarily."*

| Dimension | What it forces you to ask |
|---|---|
| **Performance** | Hot-path allocations? Hidden serializations? N round-trips for N items? Regex / pydantic / JSON cost per call? Bottleneck measured or estimated? |
| **Modularity** | Layer boundaries respected? Ports / adapters separated? Logic duplicated across files? Imports that shouldn't exist? |
| **Concurrency** | Check-then-act races? TOCTOU on quota / state / cache? Shared mutable state across tasks / goroutines? Cancellation paths? ContextVar / async-task boundary leaks? Idempotency on retry? |
| **Memory** | Bounded buffers / queues / caches? Streaming over materializing? Allocations inside loops? Unbounded growth keyed by user input? Freed aggressively on long-lived workers? |
| **Scale** | What changes at 10× traffic / rows / users / payload? Keyset vs offset pagination? Fanout bounded? Sequential I/O that should batch? Cache budget vs eviction? |

**Rules:**

1. **Tag dimension(s) per finding:** `🔴 (concurrency, scale): N sequential Redis GETs …`.
2. **Greenfield / refactor: sketch the call-outs before coding** (pre-flight table in *Output expectations*). One line of "what breaks at 10× / under concurrency / on the hot path" before the first function.
3. **A genuinely N/A dimension is stated, not skipped** — "no concurrency concerns: single-process script." Silence ≠ covered.
4. **Reviews are graded on dimension coverage, not finding count.** 20 naming nits that missed the N+1 and the unbounded queue < 5 findings hitting each lens.

This sits alongside the security threat-model, TDD, and resilience work — not instead of it.

### The scan that enforces it

Known failure mode: correctness + security findings dominate; perf / memory / concurrency / scale get relabelled, demoted to 🟢, or omitted. Run this scan *before* writing the verdict.

**Procedure.** Walk every loop, every `await`, every serialization boundary, every cache/map/dict, and every new query in the diff. Match against the catalogs below (anti-pattern fingerprints, Subtle bugs, CPU & memory budget). Any smell on a per-request / per-event / per-tool-call / per-message / per-row line is at least 🟡.

**Severity floor — anti-relabel rules:**

1. **Hot-path perf is never 🟢.** Per-request / per-event / per-row finding = minimum 🟡.
2. **Multi-dimension findings get every tag.** A 100 MB `file.read()` on the event loop is `🔴 (memory, performance)`. Dropping a tag silently shrinks coverage.
3. **No "covered in summary" demotion.** A perf finding goes inline as its own comment, not buried in the verdict.

**Output gate.** Before the inline findings, render a five-row table mapping each dimension to its findings or an explicit N/A *with a reason* (reasonless N/A fails the audit — go run that dimension's scan):

```
| Dim          | Finding(s)                                        |
|--------------|---------------------------------------------------|
| Performance  | F2 (100 MB buffer), F4 (per-request env read)     |
| Concurrency  | N/A — no new shared state, locks, or fan-out.     |
| Memory       | F2 (same as perf — tag both), F3 (unbounded cache)|
```

**Self-grade before posting:** every loop got a perf-eye? every `await` in a `for` a "should this be `gather`?"? every cache an eviction check? every new query a "10× rows" check? Missing finding → add it. Perf finding 🟢'd because "the diff is mostly correctness work" → upgrade it.

---

## Engagement principles

Full version with examples in `references/engagement.md`.

**A. Think before coding.** State non-obvious assumptions. Present multiple interpretations when ambiguous — don't pick silently. Push back when a simpler approach exists. Stop and ask when genuinely confused.

**B. Surgical changes.** In-path cleanup required (bad names, magic numbers, missing edge-case comments on lines you touch). Off-path cleanup mentioned, not made. Match existing style; remove only the imports/vars your change made unused.

**C. Goal-driven execution.** Turn imperative tasks into verifiable goals: "fix the bug" → "write a test that reproduces it, then make it pass." Multi-step tasks: state the plan with a verification per step before coding:

```
1. [step] → verify: [check]
2. [step] → verify: [check]
```

Loop independently when the success criterion is strong; confirm with the user when it's weak.

### Pre-flight checklist — 5 questions before code

Answer out loud before the first line. Any "I don't know" is the next question, not the next line of code.

1. **Where does each input come from?** External (HTTP body, queue message, form, LLM tool arg) → validate at the boundary, narrow types, bound size. Internal → trust the type signature.
2. **Who owns each resource's lifecycle?** DB conn, file handle, subscription, goroutine/task, timer — every acquire needs a matching release. Sketch the cleanup path before the happy path.
3. **What's the worst legal input?** Empty, 1-element, MAX_INT, negative, None/null, NaN, multi-byte Unicode, the largest size the contract allows. Must not crash.
4. **What happens on partial failure?** Crash mid-mutation, network blip after the write, downstream timeout, deploy rollover mid-request. Name what the caller sees and what stays consistent.
5. **How will I know it worked?** A failing test that goes green, a log line, a metric, an exit-0 command. Can't name it → can't claim done.

---

## Core principles

1. **Simplicity is the default.** Plain functions and simple data classes over inheritance. Explicit code over decorators / metaclasses / reflection / code-gen. Three files to understand one line = too clever.
2. **Each entity does one thing.** Single nameable purpose. Name contains "and" → split. `parse_and_validate_user_input` is two functions.
3. **Naming is documentation.** Long descriptive over short cryptic; `attempts_remaining` beats `n`. Units in the name: `timeout_seconds`, `max_payload_bytes`.
4. **Comments explain why, not what.** Capture the constraint that forced the choice. Density high around concurrency, retries, edge cases, external systems; low in straightforward logic.
5. **No magic numbers / strings.** Meaningful literal → named constant. Sentinel `0`/`1`/`-1` exempt.
6. **Specific exceptions, never silent failures.** Catch the narrowest exception. Every caught exception is handled meaningfully (retried, mapped to a domain error, surfaced) *and* logged with debug context, *or* re-raised with added context. `except: pass` is almost always a bug.
7. **Open for extension, closed for modification.** New requirement → extend (new strategy / handler / implementation behind an existing interface). Flag-and-branch is how single-purpose entities become monoliths.
8. **TDD by default.** Failing test → watch it fail → minimum code to pass → refactor green. Unit tests in isolation; integration tests against real-ish deps. Both required. Coverage is a leading indicator, not the goal.
9. **Shape signals that code wants splitting:**
   - **Function longer than one screen** — if you scroll, it's doing two things.
   - **Boolean parameters** — `do_thing(retry=True, dry_run=False)` is many call-shapes, few tested. Split, or take a typed `enum` / `Literal`.
   - **Tuple returns** — `(ok, value, err)` is harder to evolve than a small dataclass / struct with named fields.
10. **Lint, format, test before done.** `scripts/lint.sh`, `scripts/test.sh` are the gate.

---

## Review checklist

Run every change through these lenses. Check fires → fix it (writing) or raise it (review).

### Fast pass — anti-pattern fingerprints

30-second smoke pass. These shapes are almost always wrong:

- `except: pass` / `except Exception: pass` / Go `_ = something()` on a returned error — silenced failure.
- `# noqa` / `# type: ignore` / `eslint-disable` / `// nolint` with no inline reason.
- `==` on tokens / secrets / signatures / HMAC — timing attack. Use `hmac.compare_digest` / `subtle.ConstantTimeCompare`.
- `random.random()` / `random.choice()` / `Math.random()` for tokens / ids / session keys / reset codes. Use `secrets` (Py) / `crypto/rand` (Go) / `crypto.randomBytes` (Node).
- `assert` for runtime validation in Python — disabled under `-O`. Raise.
- `getattr(obj, dyn_name)` with a dynamic name — wants a `dict` lookup or `match`.
- `def f(items=[])` / `def f(d={})` — mutable default shared across calls. Default `None`, build in the body.
- `range(len(seq))` — wants `enumerate(seq)`.
- `if x == None` / `== True` / `== False` — use `is`.
- `for x in lst: lst.append(...)` — mutation during iteration. Iterate a copy.
- String concatenation for paths — use `Path() / "b"` (Py), `filepath.Join` (Go), `path.join` (Node).
- String-parsing URLs / datetimes / JSON / semver / IPs — use the library.
- `time.sleep()` in production code — usually a missing signal or backoff.
- `print()` in library code — should be a structured logger.
- `try` wrapping 50+ lines — narrow to the exact call that can fail.
- `try` + `finally` with no `except` (Py) / no `catch` (TS) / bare `defer fn()` whose `fn` returns an error (Go) — cleanup runs, failure invisible: caller sees the raw library exception, logs lose the domain mapping and correlation context. Add the observation branch and map to a domain error before propagating. See language refs (*try / except / finally*, *defer is Go's try/finally*, *try / catch / finally*).
- New Pydantic-less request handler (Py), validator-less JSON binding (Go), or zod-less `JSON.parse` of an untrusted payload (TS) — every untrusted boundary owes a schema. See language refs *Validation at boundaries*.
- `**kwargs` through 3+ layers — type erasure; each hop hides a typo.
- `catch (BaseException)` (Py) — also catches `KeyboardInterrupt` / `SystemExit`.
- New `os.environ.get(...)` outside the config module — config drift; also a perf smell when per-request.
- New `axios` import (TS), `requests.get` without `timeout=` (Py), `http.DefaultClient` (Go) — each has a wrong "no timeout" default.
- `// TODO` / `# TODO` added in this diff with no issue link — fix now, file the issue, or remove.

### Philosophy

Simple explicit systems over magical abstractions.

- Decorator / metaclass / reflection that hides control flow → plain call or interface.
- Implicit DI containers, auto-wiring, global registries → wire deps explicitly at the edge.
- Framework conventions requiring source-reading to predict behavior → keep the convention, leave a one-line comment on the surprising part.

### Scalability

- **Unbounded fanout.** Goroutine / task / query per item with no semaphore, batch, or cap → bound it.
- **Quadratic loops.** Nested `for` over the same growing collection → map / set lookup. Flag any `O(n²)` over user-supplied input.
- **Hidden remote calls.** Lazy getters, ORM lazy-load (N+1), "cheap" functions that call APIs → make the cost visible at the call site (rename, type, comment) or batch.

### Reliability

- **Retries.** Max attempts, backoff, jitter, non-retryable list. Idempotency verified, not assumed.
- **Cancellation.** Long work accepts a `context` / `CancelToken` / `CancelledError`. Cleanup (rollback, lock release, file close) wired to cancellation, not just success.
- **Timeouts.** Every network call, external process, blocking primitive. No default-infinite. Units in the name.
- **Backpressure.** Producers slow when consumers fall behind — bounded queues, semaphores, rate limiters. An unbounded `chan` / `Queue` / in-memory list is a memory leak with extra steps.
- **Graceful degradation.** Cache down → DB. DB down → stale-but-cached when correctness allows. One failure must not become every failure.
- **No startup health checks of deps.** Become Ready fast; first request fails gracefully if a dep is down. Blocking boot on a remote dep fights cascading recovery.

See `references/resilience.md` for breaker and pool implementations. Workflow-level reliability (cross-service, queues, idempotency) is in `references/distributed.md`. Live-system response is in `references/incident-response.md`.

### Distributed & async work

When a change crosses a process / queue / network boundary, single-call resilience is not enough.

- **Assume at-least-once delivery.** Every consumer / webhook / retry / tool call needs an idempotency mechanism — keys + dedup tables, conditional writes, or natural CAS. "Exactly-once" without a named dedup is hand-waving.
- **No dual writes.** `db.commit(); broker.publish()` lies on crash. Use CDC (preferred) or transactional outbox.
- **Distributed locks need fencing tokens** + storage enforcement. Lease-only locks (e.g. Redlock-as-written) are unsafe under GC pauses or network blips.
- **No cross-node wall-clock comparisons for correctness.** Logical clocks, version columns, monotonic counters.
- **Order is per-partition, never global** unless designed for. Retries reorder.
- **Saga over distributed transaction.** Compensations are mandatory per step; compensations themselves idempotent.

Full reference: `references/distributed.md`.

### Concurrency

When a change introduces goroutines, async tasks, channels, locks, or a worker pool — `references/concurrency.md` is the rule.

- **Structured concurrency by default.** Python: `asyncio.TaskGroup` (not `gather`). Go: `errgroup`. TS: `AbortController`-aware wrappers. Fire-and-forget without a lifecycle is a leak.
- **Cancellation propagates to the bottom.** Every `await` / RPC / blocking call receives the context. Dropping it once breaks the chain below.
- **Bounded fanout.** Semaphore-gated worker pools sized to the downstream bottleneck. No `for { go fn(item) }`.
- **No locks held across remote calls.** Acquire → mutate local → release.
- **CPU work off the event loop.** `run_in_executor` (Py), worker thread (Node), goroutine pool (Go).

### Backwards compatibility

- **API contract changes.** Public functions, REST / gRPC endpoints, message schemas, CLI flags — any rename, removed field, or shape change needs a migration path (deprecation header, dual-write, version header). `Deprecation` (RFC 9745) + `Sunset` (RFC 8594) headers on REST; field-number reservation on protobuf. Contract tests (Pact-style) catch breaks before prod. Full discipline: `references/api-contracts.md`.
- **Schema migrations.** Drop / rename column, `NOT NULL` on a populated table, type narrowing — landmines under rolling deploys. Expand → migrate → contract, across separate deploys. `CREATE INDEX CONCURRENTLY`; `NOT VALID` + `VALIDATE`; batched throttled backfills. Full pattern: `references/migrations.md`.
- **Default behavior changes.** Flipping a default silently changes every call site that took it. New value opt-in; deprecate the old later.
- **Feature-flagged rollout** for any change with non-trivial blast radius. Kill switch + gradual ladder + automated kill on SLI breach. See `references/feature-flags.md`.

### Side effects

- **Beyond the diff.** A change in a low-level helper ripples. Identify every caller and check the new contract holds — read the body, don't trust the signature.
- **Shared state.** A module-level mutable (`_CACHE = {}`, registry, singleton) the change writes to affects every reader. Document, or push state to instance scope.
- **Event emission.** Adding / renaming / removing a published event (Kafka / NATS / webhook / SSE frame) is a public-API change — treat under Backwards compatibility and `references/api-contracts.md`.
- **Caches as side effects.** A new cache layer changes consistency, adds stampede surface, and adds an invalidation contract. See `references/caching.md` — singleflight, XFetch, TTL jitter, version keys.

### Performance

The discipline lens (concrete shapes live in *CPU & memory budget*). Apply on any diff touching a hot path, claiming speedups, or running per request / item / goroutine. Full measurement loop in `references/performance.md`.

- **Claim without numbers.** "Makes X faster" with no before/after benchmark → reproduce and show the delta, or downgrade the claim.
- **Mean reported, tail hidden.** Demand p50 and p99 (p99.9 when capacity matters). Tail latency takes services down.
- **Optimized off the flamegraph.** Hand-tuning a 0.5%-of-cost function. Amdahl: same effort on the 30% line is 60× the impact.
- **Latency/throughput axes confused.** Batching that raises throughput while inflating p99 is a regression under a latency SLO. Report on the axis the diff motivates.
- **No warm-up / no statistical comparison.** Single-sample or cold-cache benchmarks are noise. Demand `benchstat`, `pytest-benchmark --compare`, or ≥10 samples with a distribution.
- **Memory change on CPU axis alone.** "10% faster" without `-benchmem` / `tracemalloc` diff — a faster path that allocates more regresses p99 via GC pressure.
- **False economies.** Micro-tweaks the compiler folds (`++i` vs `i++`), `numpy` on 10 elements, caches with no measured hit rate.
- **Optimizing business logic when the bottleneck is upstream.** Check pool/queue/timeout config before rewriting the hot function.
- **New hot-path code with no benchmark gate.** Add a CI benchmark.
- **Clever inner loops with no comment naming the measurement.** Cite the benchmark or it's debt.
- **Hot-path serialization assumed free.** `json.dumps` of a deep object, protobuf round-trip, `pickle.loads` per call — routinely top of the flamegraph.

### Runtime optimization

- **Connection pools, always.** Every networked dependency uses a pool with a sensible max. Per-request setup is a latency tax and a leak.
- **Batch and pipeline.** N round-trips for N items is wrong. Bulk inserts, multi-key fetches, Redis pipelining, prepared statements with arrays.
- **Hot-path discipline.** No allocations in per-request/item loops. Compile regex once at module load. Stream rather than materialize when input is large.
- **Don't compute until needed.** Lazy-load is good — unless it triggers a hidden remote call later (see Scalability).
- **Measure before optimizing.** `py-spy` / `cProfile` (Py), `pprof` (Go) to find the real hot spot.

### Memory — minimum, reuse where possible

- **Stream, don't materialize.** Iterators over lists; `aiter` over `await … .all()`; CSV reader over `read().splitlines()`; pagination over "load every row."
- **Reuse over reallocate.** `bytes.Buffer.Reset()`, `sync.Pool` for hot ephemerals (Go); `array`/`bytearray` reuse and slot classes for high-count objects (Py).
- **Bounded caches.** Every in-process cache has a max size and eviction policy. An unbounded `dict` keyed by user input is an OOM awaiting traffic.
- **Free aggressively.** Drop references to large objects the moment you're done — especially in long-lived workers and fan-out handlers.
- **Profile when memory matters.** `tracemalloc` (Py), `runtime.MemStats` / `pprof --alloc_space` (Go).

### Security

Threat-model before code that handles input, auth, secrets, or dependencies — five minutes is enough. Template in `references/security.md`.

- **Untrusted input** validated at the boundary with narrow types (Pydantic / Go struct + validator). Parsing is not validation.
- **Injection.** SQL / NoSQL / shell / template — always parameterize. An f-string into a query or shell command is a bug class.
- **Authn vs authz.** Every state-changing route checks *who* the caller is AND whether they own *this specific* resource. Missing the second is IDOR.
- **Secrets.** Never log, error-message, or put in URLs / env defaults. Rotate on suspicion. Constant-time compare for tokens.
- **SSRF.** User-supplied fetch URL → scheme allow-list, block private / loopback / link-local IPs, don't follow redirects to private IPs.
- **Crypto.** Strong primitives, library-managed IVs and salts. MD5 / SHA1 / `random.random()` are not for security. `secrets` / `crypto/rand` for tokens.
- **Dependencies.** Pin versions. Scan in CI. Watch the transitive graph — Python's is wide.
- **Rate limit.** Every public endpoint, especially expensive ones (LLM, sandbox, search, auth). Per-IP and per-user.
- **Defense in depth.** Validate at your layer even if the layer above did — "the caller already checked" breaks under refactors.

### Production readiness

- **Observability.** Can you answer "what's this doing right now?" from outside the process? If not, add hooks. SLO design, error budgets, RED/USE, multi-window burn-rate alerting: `references/observability.md`.
- **Logs.** Structured, correlation ids (request_id, trace_id, user_id, tenant_id) on every line. Never raw secrets or full bodies. Level matches severity — `info` state changes, `warn` self-healing failures, `error` user-visible failures.
- **Metrics.** Counter per important event, histogram per latency, gauge per queue depth / pool utilization. Labelled by the dimension you'd slice on in an incident (tenant, route, error_kind). Cardinality discipline: low-cardinality on labels, high-cardinality in logs / traces.
- **Tracing.** Every external call its own span; span attributes share correlation ids with logs. `traceparent` propagated across every boundary (HTTP, queue headers).
- **Debuggability.** Per-request log id. `/debug` or `/healthz` exposing runtime state (pool stats, breaker state, in-flight counts). Error replies carry the trace id.
- **Operability.** Kill switch / feature flag for every newly-launched user-visible feature (see `references/feature-flags.md`). Runbook per page-able alert. Rollback tested in the last 30 days. Postmortem template in place: `references/incident-response.md`.

### Testing (beyond happy path)

- **Failure-path tests.** Every `except X` and every `if err != nil { return err }` owes a test that fires it.
- **Timeout tests.** Inject a slow fake, assert the timeout fires — otherwise the timeout is a comment.
- **Concurrency tests.** Shared state / locks / channels / goroutines / tasks → tests with concurrent callers. `go test -race` on. Deterministic or property-based ordering in Python.

### Subtle bugs & corner cases — the deep pass

These escape normal review and show up in incident reports. Run on any code touching concurrency, state, time, or resource lifecycle. Think adversarially: what would the cluster have to be doing for this to be wrong?

**Concurrency.**
- **Check-then-act on shared state.** `if not_present(): create()` — two callers race past the check. Atomic upsert, `INSERT … ON CONFLICT`, or a lock around the sequence.
- **Read-modify-write without sync.** `x = redis.get(k); redis.set(k, x+1)` is a lost update. `INCR`, `WATCH/MULTI`, optimistic versioning, or a row lock.
- **Lock-order inversion.** Paths acquiring `(A,B)` and `(B,A)` → deadlock. Sort by a global order or collapse to one lock.
- **Holding a lock across I/O.** A lock around `await http.get(...)` blocks every waiter for the network latency. Acquire-mutate-release; never hold across an `await` to a remote.
- **Cancellation gaps.** `await thing()` cancelled mid-flight — did the side effect happen? Wrap commits / acks / publishes to reach a clean state; `asyncio.shield()` the must-complete bit.
- **Goroutine / task leaks.** Spawned with no stop signal. Every concurrent unit has a known exit path — pass a `context` / `AbortSignal` / shutdown event.
- **Memory-visibility hazards.** Go shared state without `sync.Mutex` / atomics → stale reads. `__slots__` is not a threading primitive.

**Locking.**
- **Wrong granularity.** One lock for the whole map serialises all readers. Shard, `sync.Map`, or read-mostly patterns when reads dominate.
- **Recursive acquisition on a non-reentrant lock.** `asyncio.Lock` isn't reentrant — a locked function called from inside the lock deadlocks.
- **Lock leaked on the exception path.** Acquire-then-raise without `finally` / `defer` holds it forever.
- **Sleeping inside a locked region.** `time.sleep(5)` in a lock burns every waiter's budget.

**Memory.**
- **Closure captures the world.** A long-lived callback capturing `request` pins the whole request graph. Extract needed fields before awaiting.
- **Listener / callback never removed.** `emitter.on("x", h)` with no matching `off` leaks per subscription.
- **Cache without eviction or TTL.** `_CACHE[user_id] = obj` keyed by user-controlled input → OOM under enumeration.
- **Defer / cleanup not running.** Early `return` before `defer file.Close()` registers; `finally` raising and masking the original error. Read the cleanup path top to bottom.
- **Slice retains the backing array.** A Go slice over a 100 MB buffer keeps it all alive. Copy the small bit out.

**Scheduling.**
- **CPU-bound work on the event loop.** `json.dumps(huge)` / `bcrypt.hashpw()` / `re.search` on a megabyte blocks every coroutine. Thread or process pool.
- **Unbounded fanout under retry.** Retry policy × parallel callers × transient failure = N × attempts of simultaneous load. Cap with a semaphore that survives across attempts.
- **Wake-up storms.** N consumers backing off the same duration retry at the same instant. Add jitter.
- **Priority inversion.** Low-priority background work holds a lock / pool slot a foreground request needs. Separate pools per priority.
- **Tail timeouts.** p99 10× p50 because one slow caller blocks the pool. Per-call deadline + adaptive concurrency.

**Time, encoding, boundaries.**
- **Empty / single-element input.** `[].max()`, `"".split(",")`, single-element pagination. Every iteration owes a 0-item and 1-item test.
- **Integer overflow.** `int * 1024 * 1024` on `int32` (Go) wraps negative. Byte/bit and message-size math are the usual sites.
- **Boundary values.** 0, 1, MAX_INT, negative, None, NaN, +Inf. The pagination off-by-one hits at page 0 or the last page.
- **Clock skew.** TTL / expiry / "newer than" across nodes with different clocks. One source of truth (DB, monotonic counter) or tolerate skew explicitly.
- **DST / timezone.** `datetime.now()` without tz; "midnight local" schedules fire twice a year. Store and compare in UTC.
- **Unicode and length.** `len(s)` is code-points (Py), bytes (Go). A "10-char" username can be 40 bytes in UTF-8. Length-bounded buffers count bytes.
- **Crash mid-mutation.** Wrote half the rows, then died. The next request must not assume "no rows" or "all rows" — transactions, idempotent retries, or a marker row.
- **`LIMIT` without `ORDER BY`.** Postgres returns undefined order. Always pair with `ORDER BY id` (or a stable key).

### CPU & memory budget — review for waste

Past correctness, scan for cycles and bytes the change doesn't earn. Ask: "would I keep this if it had a measurable cost line attached?"

- **Unnecessary work.** Computed-and-never-used, loaded-and-discarded, logged at a silenced level (eval cost paid anyway). Delete it.
- **Recomputation in a loop.** Same lookup / compiled regex / env read every iteration. Hoist or memoize.
- **Wrong-shape data structure.** Linear scan where a set/map is O(1). `if x in list_of_10000`.
- **Materialising intermediates.** `list(map(f, list(filter(g, items))))` builds two throwaway lists. Generator pipeline + one consumer.
- **Allocation in hot paths.** New buffer per request, dict per row, closure per call. Pool, hoist, or pre-allocate to known capacity.
- **Serialise-then-reparse.** `json.loads(json.dumps(x))` for a deep clone; `dict(other)` then mutate. `copy.deepcopy` only when needed.
- **Log eval at a silenced level.** `logger.debug(f"big {expensive()}")` evaluates even when debug is off. `%`-style or `isEnabledFor`.
- **Eager evaluation of optional paths.** Computed for an `if` branch that runs 1% of the time. Defer to inside the branch.
- **Reflection / dynamic dispatch on hot paths.** `getattr(obj, name)` in a loop, `encoding/json` reflection on a write-heavy path. Cache the access or code-generate a marshaler.
- **Float where int suffices.** Counter, score, byte count, timestamp-in-ms → `int`.
- **Bouncing encoding.** `bytes → str → bytes → str` round-trips. Pick a side at the boundary and stay.
- **Copy when you could window.** Slicing a 1 GB buffer to read the header copies it. `memoryview` (Py), slice header (Go), `Buffer.subarray` (Node).
- **String concatenation in loops.** `s += part` is O(n²) on immutable strings. Accumulate + join / `strings.Builder` / `Buffer[]`.

### Escalation — flag for senior review

Surface in the PR description, not just chat:

- Schema migrations (any DDL). See `references/migrations.md`.
- Public API contract changes (REST / gRPC / SDK / webhook surface). See `references/api-contracts.md`.
- New framework / library / vendor adoption.
- Performance-critical hot paths (request handler, ReAct loop, queue consumer, fan-out worker).
- Security-sensitive functionality (auth, secrets, crypto, untrusted input).
- Anything that fans out across services on deploy.
- New cross-service workflow / saga / outbox / CDC stream. See `references/distributed.md`.
- New distributed lock or leader election. See `references/distributed.md` → coordination.
- New SLO, alert, or kill switch — touches the operational contract. See `references/observability.md` and `references/feature-flags.md`.
- New cache layer with non-trivial blast radius (shared, high-traffic, or correctness-sensitive). See `references/caching.md`.

---

## Diff-shape heuristics

Look at the *shape* before the contents:

- **> 500 net lines.** Attention degrades. Suggest splitting by concern.
- **> 10 files, mixed concerns.** "feat: add X, fix Y, refactor Z" is three PRs.
- **Test count fell while code rose.** Contract change (call it out) or silent coverage regression.
- **No new test alongside a new branch.** Every new `if` / `switch` arm owes a test.
- **Lock file changed without a manifest change.** Transitive bump — sometimes a CVE fix, sometimes a silent regression. Note it.
- **Pure rename or move.** Verify no behaviour change — Git's rename detection occasionally hides edits.
- **Comment density dropped.** Deleted context. Check each deletion.
- **New `// TODO` / `# TODO` in committed code.** Fix now, file the issue, or delete.

---

## Review-mode output style

Goal: the receiving developer reads the comment, gets it in plain English, and can apply the fix without further context.

**Per-comment format — WHAT / WHY / FIX:**

```
path/to/file.py:42 — 🔴 must-fix

WHAT: The retry loop has no maximum attempts — it can loop forever
if the downstream stays unreachable.

WHY: Unbounded retry under a flapping downstream holds this request,
its pool connection, and any locks — indefinitely; requests queue
behind the stuck slot until the pod OOMs. Standard pattern: bounded
retry + exponential backoff + breaker outside. (See code-craft →
Reliability → Retries.)

FIX:
    for attempt in range(MAX_RETRIES):       # was: while True
        try:
            return call_downstream()
        except RetryableError:
            backoff(attempt)
    raise GiveUp()
```

**Rules:**

1. **One issue per comment.**
2. **Always WHAT / WHY / FIX.** WHAT = one line naming the defect. WHY = the teachable part: runtime mechanism, consequence (what breaks, for whom, when), principle violated — 2–4 sentences. FIX = concrete change, ideally code.
3. **Plain English in all three.** "this fans out without a cap" — not "violates the bounded-concurrency invariant."
4. **Concrete fix.** Two-line fix → paste it. Structural fix → sketch the shape in 3–5 lines. Words → under three sentences.
5. **Severity tag.** 🔴 must-fix (correctness, security, data loss, crash) / 🟡 should-fix (reliability, performance, maintainability cliff) / 🟢 nice-to-have (clarity, naming, in-path polish). **Add the dimension tag** when driven by one of the five. **Each review must visibly engage all five dimensions** at least once, or state in the verdict that one was N/A. Zero perf/concurrency/memory/scale findings on a diff touching an SQL query, a queue, or a hot path = incomplete review.
6. **One impact sentence when severity ≥ 🟡.**
7. **Link the principle when non-obvious** ("See code-craft → Scalability → hidden remote calls").
8. **Skip noise.** No praise, no restating the diff, no linter-caught items, no drive-by style preferences.
9. **Suggest, don't dictate.** Two reasonable fixes → name both, recommend one.
10. **Tone.** Polite, neutral, peer-not-defendant. Uncertain → phrase as a question: "Have you considered what happens when X?"
11. **Actionable, not vague.** "This could be cleaner" is noise — name the change or skip the comment.
12. **Approve when only minor issues remain.** Risk reduction, not perfect code. Don't block on style or 🟢 — comment and approve.

### Review posture

- **Two passes.** First skim every file to map what's changing; then comment. First-pass comments are often wrong because you hadn't seen file three.
- **Ask "why this, not that".** Every non-obvious choice has an answer; phrase as a question.
- **Cap one stretch at ~400 lines.** Past that, comments drift to noise.
- **Walk away when you start nit-picking** — drifting from bugs to taste is the fatigue signal.
- **Don't fix it yourself in the review.** Suggest, don't commit.
- **Self-check each comment before posting.** WHAT specific? WHY names the mechanism? FIX works as written? Any "no" → rewrite or delete.

---

## Receiving review feedback

The default LLM behavior — perform agreement, implement immediately — is wrong on both counts.

**No performative agreement.** Skip "You're absolutely right!" / "Great point!" — status signals, not engineering. Don't code before understanding the comment; the reviewer may be wrong, missing context, or pointing at a symptom. Restate the change in your own words, ask if unclear, push back with a technical reason if wrong — *then* implement.

**Receiver pattern: READ → UNDERSTAND → VERIFY → EVALUATE → RESPOND → IMPLEMENT.**

1. **READ** every comment fully first — they interact (#3 may invalidate #1).
2. **UNDERSTAND** — restate the ask in one sentence; if you can't, ask.
3. **VERIFY** the technical claim. "This is N+1" → grep the call sites. "Crashes on empty input" → run it. Reviews can be wrong.
4. **EVALUATE** cost vs benefit. A "proper" refactor adding three files for one use case is a YAGNI violation — say so.
5. **RESPOND** before implementing when contested. Agree on the change, or agree to leave it — then code.
6. **IMPLEMENT** with verification (next section). No "done" until verification passed.

**Source handling.** Trusted partner / your own diff → implement after understanding; skip verify only when unambiguous. External reviewer → verify the claim first. If wrong, push back with evidence: "I checked X and it does Y because Z — am I missing something?"

---

## Output expectations (writing code)

1. **Engage before coding** — for non-trivial tasks: assumptions, ambiguities, simpler alternatives; ask if genuinely unclear.
2. **State the mode** (greenfield / refactor / review) at the top, one line.
3. **State the plan** for multi-step tasks, with a verification per step.
4. **Greenfield:** test first, then implementation — show both.
5. **Refactor:** show the diff or changed sections, not the whole file. Note in-path cleanup; mention off-path smells separately without changing them.
6. **Surface non-obvious decisions** ("I introduced an interface here because…").
7. **Visibly engage the five dimensions** — render this pre-flight table *before* the first function body:

   ```
   | Dim          | Pre-flight call-out                                   |
   |--------------|-------------------------------------------------------|
   | Performance  | What runs per request / per item? Where's the cost?   |
   | Modularity   | Where's the seam? What did I refuse to couple?        |
   | Concurrency  | Shared state? Cancellation path? Idempotency on retry?|
   | Memory       | What's bounded? What gets freed when?                 |
   | Scale        | What changes at 10×? Pagination, fanout, payload.     |
   ```

   One line per dim minimum. "N/A — single-process script" is valid; silence isn't. Hot-path / data-plane work owes a measured (or estimated, with units) cost line on Performance.
8. **End with the lint/test command** for the user, and confirm each plan step's verification passed.

Avoid: long preambles, silent assumptions on ambiguous requests, drive-by refactoring of off-path code, fabricated "best practices" not in this skill or its references, cleverness that doesn't earn its keep, silently skipping the five dimensions.

---

## Verification gates — before claiming done

**Iron law: no completion claim without fresh verification evidence.** About to type "tests pass" / "build is green" / "the bug is fixed" / "ready to merge"? You owe the output of the command that proves it. "Should" / "probably" / "seems to" before a completion claim is the same as lying.

**Gate: IDENTIFY → RUN → READ → VERIFY → CLAIM.**

1. **IDENTIFY** the command that proves the claim (`scripts/test.sh`, `scripts/lint.sh`, the reproducer, the benchmark).
2. **RUN** the full command — not a subset.
3. **READ** the output — exit code, failure count, the specific lines.
4. **VERIFY** it supports the claim. "Tests pass" = 0 failures in the output, not "no big errors shown."
5. **CLAIM** with evidence inline: "Tests pass — `scripts/test.sh` exited 0, 234 passed, 0 failed."

**Required evidence per claim:**

| Claim | Evidence |
|---|---|
| Tests pass | Runner output: 0 failures + pass count |
| Build succeeds | Build command exit 0 |
| Lint clean | Lint command exit 0 |
| Type check clean | `mypy --strict` / `tsc --noEmit` exit 0 |
| Bug fixed | A test reproducing the original symptom now passes |
| Performance better | Benchmark numbers before *and* after |
| Requirements met | Line-by-line checklist mapping requirement → evidence |

**Red flags — stop and verify:** "should pass" / "probably works" / "seems fine" without running it; satisfaction expressed before any verification ran; committing or pushing without local tests + lint; trusting a subagent's report without re-running; any wording implying success while skipping the gate.

**Done-gate scripts:** `scripts/lint.sh` (format + lint), `scripts/test.sh` (test with coverage).
