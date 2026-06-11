# Resilience patterns

Open this when designing or modifying code that talks to an external
dependency: database, cache, message queue, HTTP service, third-party API.
Applies in Python and Go; concrete code in `python.md` / `golang.md`.

## The four non-negotiables

Every external dependency call must have:

1. A **connection pool** sized for expected concurrency.
2. A **timeout** — connect *and* read/write.
3. A **circuit breaker** — fail fast when the dependency is unhealthy rather
   than holding requests open.
4. A **retry policy with bounded backoff** — for genuinely transient failures,
   hard-capped.

Missing any is a production incident waiting. Add them at design time;
retrofitting is harder than it sounds.

## Connection pools

A pool reuses connections; without one, every request pays a TCP (and TLS)
handshake — 30–300 ms — before any work, and under load you exhaust file
descriptors and the OS refuses connections.

Sizing (concurrency = QPS × avg latency, **not** QPS):

- **DB pool = concurrent in-flight queries.** 1000 QPS × 5 ms = concurrency 5
  → pool 10–20. 100 QPS × 500 ms = concurrency 50 → much bigger pool.
- **HTTP client pool ≥ concurrent in-flight requests.** Too small serializes;
  too large wastes memory and can overwhelm the upstream.
- **Redis/cache pool: small.** Submillisecond calls → low concurrency even at
  high QPS. 10–50 usually right.

Also configure: **max idle connections** (kept warm in quiet periods);
**connection max lifetime** (recycle every N min so DNS changes, cert
rotations, LB reshuffles take effect); **connect timeout** ~1–2 s (a longer
connect is a network problem — don't wait).

## Timeouts

- **Connect timeout** — TCP/TLS handshake wait. Short, 1–2 s.
- **Read/write (operation) timeout** — tuned per call: a health ping ~100 ms, a
  heavy report query ~30 s. No universal value.

A request without a timeout is a goroutine/task held forever — one stuck
downstream parks every worker and takes the service down.

Python: timeouts on the client (`httpx.Timeout`,
`asyncpg.create_pool(command_timeout=...)`). Go: on the `Context`
(`context.WithTimeout`) and on the client `Transport`. Use both — client-level
cap as backstop, per-call context for tuning.

## Circuit breakers

Tracks downstream health and short-circuits when unhealthy. States:

- **Closed** (healthy): calls pass; failures counted.
- **Open** (unhealthy): calls fail immediately without touching the downstream;
  after a cooldown → half-open.
- **Half-open**: a few probes pass through; success → closed, failure → re-open
  with a longer cooldown.

Why it matters: **fast-fail** (a 30 s timeout becomes a microsecond error — user
unblocked, worker freed, upstream not piling up retries); **backpressure on a
struggling downstream** (the worst thing a caller can do to an overloaded
service is keep retrying); **bounded blast radius** (one sick dependency doesn't
cascade).

Tuning: **failure threshold** ~5 consecutive failures or 50% over a window
(sensitive enough to react, not so trigger-happy one slow query opens it);
**open duration** start 30 s (long enough to recover, short enough that a blip
isn't minutes of downtime); **scope** per-host for multi-upstream HTTP,
per-pool for a single DB.

Python: `purgatory`, `circuitbreaker`, or roll your own around the asyncio call.
Go: `sony/gobreaker`. Either way the breaker wraps the call site, not the
transport.

## Retry policies

Retry *transient* failures (network blips, brief restarts, transient DB
deadlocks) — not *permanent* ones (bad request, auth failed, `400` on malformed
input). A retry on a `400` is a bug; distinguish before retrying.

When retrying:

- **Exponential backoff with jitter.** Doubling (50/100/200/400 ms) ± ~50%
  random so many callers don't synchronize.
- **Hard cap on attempts.** Three is usually enough; five is a lot; ten is
  almost always wrong.
- **Hard cap on total wall-clock.** A 1 s SLA can't afford five exponential
  retries.
- **Idempotency awareness.** Safe only if the op is idempotent. A POST without
  an idempotency key can't be retried after an unknown-state failure — it may
  have succeeded, and retrying duplicates.

Layer the breaker *outside* the retry: retry handles blips; if blips become a
pattern, the breaker takes over and stops retrying.

## Lazy startup — no startup health checks

The most important pattern, and the most often violated. **Do not block startup
on a successful Postgres connect, Redis ping, or NATS subscribe.**

Arguments, in order:

- **Autoscaling fights you.** Blocking on a dep adds seconds to time-to-ready
  while existing pods are overloaded. The new pod should start, accept its first
  request, and let that request hit the dep naturally.
- **Cascading restart loops.** A Postgres hiccup fails every pod's startup
  probe → mass restart → a thundering herd of reconnects on top of the hiccup.
  An already-started app survives a 30 s blip; a fleet that restarts on it
  doesn't.
- **First-request latency is acceptable** — a cold pool's first request is
  slower; users don't notice, metrics see a small tail.
- **Deps legitimately come and go** — replicas rotate, caches fail over. The
  runtime code that handles this gracefully is the same code that handles
  startup; a startup-only path adds nothing.

What the app should do: **start** (bind socket, become Ready, accept requests);
**initialize pools lazily** or with non-blocking connect (first request triggers
first connect); **handle the initial connection failure** like any other
(timeout, breaker, error to caller, client retries).

K8s probes are fine — but probe the *app*, not the deps. A liveness probe
returning 200 if the process can respond is correct; one that pings the DB
conflates "this pod is broken" with "the DB is broken" and restarts healthy
pods on an upstream problem.

## Graceful degradation

A dep being down isn't always "500 to the user" — often a fallback is worse
than the happy path but better than nothing:

- **Cache miss + DB down** → return stale-but-cached if the data model
  tolerates it (many do).
- **Recommendation service down** → return a generic non-personalized list,
  not an error.
- **Analytics write fails** → buffer locally / dead-letter; don't block the
  user-facing request on it.

This is a product decision as much as engineering — have the "what does each
path look like when the world is on fire" conversation up front.

## The shape of one resilient call

```
caller
  → enter circuit breaker (fast-fail if open)
  → enter retry loop (backoff + jitter, bounded)
  → acquire connection from pool (connect timeout)
  → execute call (operation timeout, cancellable context)
  → release connection back to pool
  ← return result or wrapped domain error
```

Adapter packages exist so this shape is written once per dependency type, not
per call site.

**Inside the adapter:** connection management, transient-failure retry, error
wrapping into domain errors, observability (metrics/traces/logs).
**Outside:** circuit breaker (its state should survive adapter recreation),
business-level retries ("retry the whole workflow"), cancellation context.
