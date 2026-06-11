# Resilience patterns

Open when designing or modifying code that talks to an external dependency: database, cache, queue, HTTP service, third-party API. Concrete code in `python.md` / `golang.md`.

## The four non-negotiables

Every external dependency call must have:

1. A **connection pool** sized for expected concurrency.
2. A **timeout** — both connect and read/write.
3. A **circuit breaker** — fail fast when the dependency is unhealthy.
4. A **retry policy with bounded backoff** — for genuinely transient failures, hard-capped.

Missing any is a production incident waiting. Add at design time; retrofitting is harder than it sounds.

## Connection pools

Without a pool, every request pays a TCP (+TLS) handshake — typically 30–300ms — and under load you exhaust file descriptors.

Sizing:

- **DB pool size = expected concurrent in-flight queries**, not QPS. Concurrency = QPS × avg query latency. 1000 QPS × 5ms queries = concurrency 5 → pool 10–20. 100 QPS × 500ms = concurrency 50 → much bigger pool.
- **HTTP client pool ≥ expected concurrent in-flight requests.** Too small serializes; too large wastes memory and may overwhelm the upstream.
- **Redis / cache pool: small.** Submillisecond calls → low concurrency even at high QPS. 10–50.

Also configure: **max idle connections** (warm during quiet periods); **connection max lifetime** (recycle every N minutes so DNS changes, cert rotations, LB reshuffles take effect); **connect timeout** (1–2s — longer is almost certainly a network problem).

## Timeouts

Two needed:

- **Connect timeout** — TCP/TLS handshake. Short: 1–2 seconds.
- **Read/write (operation) timeout** — tuned per call. Health-check ping 100ms; heavy report query 30s. No universal value.

A request without a timeout is a goroutine/task held forever; one stuck downstream parks every worker and takes the service down.

Python: timeouts on the client (`httpx.Timeout`, `asyncpg.create_pool(command_timeout=...)`). Go: on the `Context` (`context.WithTimeout`) AND the client `Transport` — client-level cap as backstop, per-call context for tuning.

## Circuit breakers

States:

- **Closed** (healthy): calls go through; failures counted.
- **Open** (unhealthy): calls fail immediately. After a cooldown → half-open.
- **Half-open**: a few probe calls. Succeed → close; fail → re-open with longer cooldown.

Why: **fast-fail** (microseconds instead of a 30s timeout — user errors sooner, worker freed sooner, upstream stops piling retries); **backpressure** on a struggling downstream (the worst thing a caller can do is keep retrying); **bounded blast radius** (one sick dependency doesn't cascade).

Tuning:

- **Failure threshold:** typically 5 consecutive failures or 50% failure rate over a window. Sensitive enough to react; not so trigger-happy one slow query opens it.
- **Open duration:** start at 30 seconds, tune.
- **Granularity:** per-host for HTTP clients to multiple upstreams; per-pool for a single database.

Python: `purgatory`, `circuitbreaker`, or roll your own. Go: `sony/gobreaker`. The breaker wraps the call site, not the transport.

## Retry policies

Retry *transient* failures only (network blips, brief restarts, transient deadlocks) — never *permanent* ones (bad request, auth failure, `400` on malformed input). **A retry on a `400` is a bug.**

When retrying:

- **Exponential backoff with jitter.** Doubling delay (50/100/200/400ms…) ± ~50% random jitter so callers don't synchronize.
- **Hard cap on attempts.** Three is usually enough. Five is a lot. Ten is almost always wrong.
- **Hard cap on total wall-clock.** A 1-second-SLA request can't afford five exponential retries.
- **Idempotency awareness.** Retries are safe only if the operation is idempotent. POST without an idempotency key cannot be retried after an unknown-state failure — it might have succeeded; retrying duplicates.

Layer the breaker **outside** the retry: retry handles blips; when blips become a pattern, the breaker stops retrying entirely.

## Lazy startup, no startup health checks

The most important pattern, the most often violated. **Do not block startup on dependency health** — no blocking Postgres connect, Redis ping, or NATS subscribe at boot.

Why:

- **Autoscaling fights you.** A new pod spun up under load that blocks on a dep adds seconds to time-to-ready while existing pods drown. It should start, accept its first request, and let that request hit the dependency naturally.
- **Cascading restart loops.** A Postgres hiccup → every pod whose startup probe touches Postgres fails and restarts → thundering herd of reconnects on top of the original problem. A started app survives a 30-second blip; a fleet restarting on the blip does not.
- **First-request latency is acceptable.** Cold pool on the first request is a small tail; users don't notice.
- **Dependencies legitimately come and go** (replica rotation, cache failover). Code that handles these at runtime is the same code that handles them at startup — a separate startup-only path adds nothing.

What the app should do: **start** — bind the socket, become Ready, accept requests; **initialize pools lazily** or with non-blocking connect; **handle the initial connection failure like any other** — timeout, breaker, error to caller, client retry.

Kubernetes probes: probe the *application*, not the dependencies. A liveness probe returning 200 if the process responds is correct; one that pings the database conflates "pod broken" with "database broken" and the cluster restarts healthy pods over an upstream problem.

## Graceful degradation

A dependency down doesn't always mean "500 to the user":

- **Cache miss with DB down:** stale-but-cached response if the data model tolerates it. Many do.
- **Recommendation service down:** generic non-personalized list, not an error.
- **Analytics write fails:** local buffer or dead-letter queue; never block the user-facing request on an analytics write.

Degradation is a product decision as much as engineering — have the conversation up-front about what each path looks like when the world is on fire.

## The shape of a resilient call

```
caller
  → enter circuit breaker (fast-fail if open)
  → enter retry loop (backoff + jitter, bounded)
  → acquire connection from pool (with connect timeout)
  → execute call (operation timeout, cancellable context)
  → release connection back to pool
  ← return result or wrapped domain error
```

Every external call fits this shape. Adapter packages exist exactly so it's written once per dependency type, not once per call site.

## Inside the adapter vs outside

- **Inside:** connection management, retry policy for transients, error wrapping into domain errors, observability (metrics, traces, structured logs).
- **Outside:** circuit breaker (its state should survive adapter recreation), business-level retries ("retry the whole workflow"), cancellation context.
