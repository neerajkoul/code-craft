# Concurrency

Open when writing or reviewing code with goroutines, async tasks, channels, locks, worker pools, or anything that can run "at the same time as itself." Complements `SKILL.md`'s *Concurrency* / *Locking* / *Scheduling* subtle-bug sections — this is the design layer: which primitive, why, and how to compose them safely.

## Primitive choice — locks vs channels vs CAS vs sharding

| Need | Right primitive |
|---|---|
| Mutate one shared structure briefly | Mutex (`sync.Mutex`, `asyncio.Lock`, `Mutex<T>`) |
| Hand off ownership of data between tasks | Channel (Go), `asyncio.Queue`, MPSC channel (Rust) |
| Counter / single-cell update | Atomic / CAS (`atomic.AddInt64`, `compare_exchange`) |
| State partitionable by key | Single-flight per key (no shared mutation at all) |
| Many readers, occasional writers | `sync.RWMutex`, `RwLock` — but only if measured contention warrants |
| Coordinate "this many in flight at once" | Semaphore / bounded channel |
| One thing happens at a time across a process | Mutex |
| One thing happens at a time across a fleet | Distributed lock + fencing (see `distributed.md`) |

**Default order of preference:** sharding > CAS > channels > mutex. Lower-numbered options eliminate contention; higher-numbered manage it. A mutex is the right tool when nothing simpler works — not the first reach.

## Structured concurrency

The discipline: every concurrent unit has a defined lifetime, an owner, and a guaranteed cleanup path. No fire-and-forget tasks; no goroutines launched into the void.

**Python (3.11+):**
```python
async with asyncio.TaskGroup() as tg:
    tg.create_task(work_a())
    tg.create_task(work_b())
# block exits only when both tasks complete or one raises.
# raise → siblings cancelled; ExceptionGroup propagated.
```

`asyncio.gather(...)` is *not* structured — on first exception, siblings keep running. Use `TaskGroup` (or AnyIO / Trio's `nursery`).

**Go:** `golang.org/x/sync/errgroup` for the same shape:
```go
g, ctx := errgroup.WithContext(ctx)
g.Go(func() error { return workA(ctx) })
g.Go(func() error { return workB(ctx) })
if err := g.Wait(); err != nil { ... }
```
The shared `ctx` cancels siblings when one errors. Don't `go fn()` without an errgroup unless the goroutine genuinely outlives the request (background worker with its own lifecycle).

**TypeScript:** `Promise.all` cancels nothing on rejection — sibling promises run to completion. Use `AbortController` + a wrapper that signals abort when any rejects, or libraries like `p-cancelable`.

## Cancellation propagation

A cancelled call must tear down everything it spawned. Required disciplines:

- **Every long-running call accepts a cancellation token** (`context.Context`, `asyncio.CancelledError`, `AbortSignal`). No exceptions.
- **The token reaches the bottom.** Every downstream call, every `await`, every blocking primitive. Drop it once → the whole chain becomes uncancellable below that point.
- **Cleanup is wired to cancellation, not just success.** `try/finally` (Py), `defer` (Go), `try/finally` (TS) — releases run on the cancel path. A breaker open count that increments on cancel but not on the cleanup path leaks.
- **Don't swallow `CancelledError`.** Catching `asyncio.CancelledError` and not re-raising breaks `TaskGroup` / `asyncio.timeout()`. If you must catch it for cleanup, re-raise after the cleanup.
- **Cancellation is cooperative.** A CPU-bound loop without `await` / `select` / yield doesn't cancel. Insert checkpoints in long compute, or run it in a worker pool with a stop signal.

## Backpressure

Producer faster than consumer + unbounded buffer = OOM with extra steps.

**Patterns:**
- **Bounded channel / queue.** Producer blocks (or selects on shutdown) when full. `make(chan T, 100)`, `asyncio.Queue(maxsize=100)`. Default in Go's standard channel idiom.
- **Semaphore-gated worker pool.** N workers, each pulls from the queue; queue capped. Bound total in-flight work.
- **Drop policies.** Newest-wins (replace), oldest-wins (ring buffer), reject-with-error (429). Pick deliberately.
- **Token bucket / leaky bucket at the entrance.** Cap rate, not just concurrency.

A `chan T` with no buffer **is** backpressure: producer blocks until a consumer is ready. A `make(chan T, 1000000)` is unbounded for practical purposes — same bug, slower failure.

## Worker pools — bounded fanout

`go func() { handle(item) }()` per item is wrong:
- Spawn cost × N items = ms of latency overhead.
- No bound → OOM under burst.
- No semaphore → downstream sees N concurrent calls.
- No way to cancel mid-flight.

**Right shape:**
```go
sem := make(chan struct{}, 10)  // 10 concurrent
g, ctx := errgroup.WithContext(ctx)
for _, item := range items {
    item := item
    sem <- struct{}{}
    g.Go(func() error {
        defer func() { <-sem }()
        return handle(ctx, item)
    })
}
return g.Wait()
```

Python:
```python
sem = asyncio.Semaphore(10)
async def bounded(item):
    async with sem:
        return await handle(item)
async with asyncio.TaskGroup() as tg:
    for item in items:
        tg.create_task(bounded(item))
```

Sizing: usually the bottleneck downstream's concurrency. DB pool 20 → semaphore 20 (not 200).

## Mutex hygiene

- **Hold for the smallest scope.** Acquire → mutate local → release. No `await` / network call inside.
- **`try`/`finally` (Py), `defer` (Go), `using` (C#-like)** to release on exception paths.
- **No re-entrant calls into a non-reentrant lock.** `asyncio.Lock` isn't reentrant — locked function called from inside its lock = deadlock.
- **Sort lock acquisition.** Path A locks `(X, Y)`, path B locks `(Y, X)` → deadlock under crossing traffic. Global ordering or single combined lock.
- **No `time.sleep` / `await sleep` inside a locked region.** Every waiter parks for that sleep.
- **`RWMutex` only with measured contention** — read locks aren't free; under low contention, `Mutex` is faster.

## Async-specific traps

**Event-loop blocking.** Sync CPU work in an `async` function freezes every coroutine:
- `json.dumps(huge_obj)` — 100ms blocked = 100ms latency on every concurrent request.
- `bcrypt.hashpw()` / `re.search(huge_pattern, huge_string)` — same.
- `time.sleep(1)` (sync) — kills the loop. Use `await asyncio.sleep(1)`.

Push CPU work to `loop.run_in_executor(...)` (threads) or `ProcessPoolExecutor` (CPU-bound + Python GIL).

**ContextVar leaks.** `ContextVar` is per-task. A value set in `request_handler` is visible inside any task it spawns — but *not* inside background tasks that outlive the request. Audit which boundary the value should cross.

**`asyncio.gather` vs `TaskGroup`.** `gather` masks errors (when `return_exceptions=True`); leaves siblings running on exception (when `False`). Both wrong as defaults. `TaskGroup` is the structured replacement (3.11+).

## Go-specific traps

**Goroutine leaks.** Every `go fn()` needs a known exit. Common leak: `select { case <-ch: ... }` with no `case <-ctx.Done():` — goroutine blocks forever if the producer stops. Audit every `select` for a cancellation arm.

**`sync.WaitGroup` without timeout.** `wg.Wait()` blocks until counter hits zero, period. A leaked goroutine that forgets `wg.Done()` → forever. Either `errgroup` (cancels on error) or a `select { case <-done: ; case <-time.After(t): }`.

**Closure variable capture in `for` (pre-Go 1.22).** `for _, x := range xs { go fn(&x) }` captures the same `x` slot. Fix: `x := x` shadow inside the loop. Go 1.22+ changed loop semantics; check the project's Go version.

**Map under concurrent access — no error, just corruption.** Single goroutine writes, others read = data race. `sync.Map` (read-mostly) or mutex-wrapped map.

## TS-specific traps

**`Promise.all` masks cancellation.** No abort propagation. Use `Promise.allSettled` if you want all results, or implement abort with `AbortController`.

**Microtask flood.** Awaiting a million promises queues a million microtasks. Batch with `p-limit` / `p-queue` (`p-limit(10)` → 10 concurrent).

**`setTimeout` for backpressure** — wrong tool. Use a bounded queue or token bucket.

## Actor model (where it fits)

When state is naturally per-entity and contention is high: route all messages for entity E through one handler. The handler owns the state; no locks needed. Implementations:
- Go: channel + single goroutine per entity (or a sharded set of goroutines).
- Erlang/Elixir: actors are the language model.
- Frameworks: Akka, Orleans, Ray.

Trade-off: per-actor mailbox memory; per-actor scheduling overhead. Right at high-cardinality state (user sessions, chat rooms); wrong for low-cardinality (one global counter).

## Anti-pattern fingerprints

- `go fn()` with no `ctx` / no errgroup — leak risk. 🟡
- `asyncio.gather` for fan-out (not `TaskGroup`) — sibling errors hidden. 🟡
- `for { go work(item) }` no semaphore — unbounded fanout. 🔴 (scale)
- Mutex held across `await` / network call — pool drain. 🔴 (concurrency)
- `time.sleep` (sync) inside `async def` — event-loop block. 🔴
- `CancelledError` caught and not re-raised — `TaskGroup` semantics broken. 🔴
- Channel `make(chan T, 1000000)` — pseudo-unbounded. 🟡
- `WaitGroup` with no timeout / no cancel arm — deadlock on leak. 🟡
- `sync.Map` used for write-heavy workload — slower than mutexed map. 🟢 (perf)
- Lock acquisition order varies by code path — deadlock waiting. 🔴

## Checklist

- [ ] Concurrent units are structured (TaskGroup / errgroup) — no fire-and-forget unless lifecycle is named.
- [ ] Cancellation token threads through every hop.
- [ ] CPU-bound work doesn't run on the event loop.
- [ ] Every fanout has a semaphore / bounded queue / worker pool sized to the downstream.
- [ ] Locks: smallest scope, no I/O inside, deferred release, consistent acquisition order.
- [ ] Backpressure: bounded buffers, named full-policy.
- [ ] Tests: race detector (Go `-race`), concurrent callers exercising the shared state.
