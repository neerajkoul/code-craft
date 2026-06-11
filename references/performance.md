# Performance

Open when touching a hot path, when a service hits a latency/throughput SLO, when a benchmark regresses, or when reviewing a diff motivated by "make it faster." Complements the `Runtime optimization`, `CPU & memory budget`, and `Memory` sections in `SKILL.md`: those say *what shapes are wrong*; this says *how to find what's actually costing you*.

## The iron rule

**No optimization without a measurement.** A function at the top of a flamegraph is engineering; a `for` loop that "feels slow" is folklore. No before-and-after number = theatre. This holds even for "obviously" faster changes:

1. **The bottleneck is rarely where you think.** The suspect costs 2%; the surprise hot spot is a forgotten logging call.
2. **Optimizations have hidden costs.** Faster algorithms that allocate more, break vectorization, or hurt cache locality can lose in production despite winning the micro-benchmark.
3. **Legibility is a real budget.** A clever 3% win is a 3% regression in the next maintainer's understanding. Pay for clever only when the data demands it.

## The measurement loop

Five steps. Skip any and you're guessing.

1. **Reproduce the symptom** — a benchmark, load test, or recorded request you can run repeatedly.
2. **Capture a baseline** — p50, p95, p99, and throughput separately. One number is a lie of omission.
3. **Profile** — CPU profiler for CPU-bound, memory profiler for memory, tracing for cross-service. Read the flamegraph before touching code.
4. **Change one thing.** Otherwise the post-change number tells you nothing.
5. **Re-measure** — same benchmark, load, machine state.

If steps 2 and 5 aren't comparable (different machine/load/warm state), the experiment is invalid — start over.

## Profilers per language

### Python
- **`py-spy`** — sampling, attach to a running process, low overhead. First reach: `py-spy record -o flame.svg -- python -m my_service`. Works on prod.
- **`cProfile`** — deterministic, stdlib, higher overhead; offline single-script analysis. `python -m cProfile -o out.prof script.py` then `snakeviz`.
- **`tracemalloc`** — stdlib memory; allocation source lines, snapshot diffs. Leaks and per-request bloat.
- **`memray`** — sampling memory flamegraphs; better signal than tracemalloc for hot allocators.
- **`pytest-benchmark`** — micro-benchmarks; lock the baseline, run in CI for regressions.

### Go
- **`go test -bench=. -benchmem -count=10`** — table-stakes for any perf PR. Without `-benchmem`, allocation regressions hide.
- **`pprof`** — against `/debug/pprof/profile` (CPU), `/heap` (alloc), `/goroutine`. `web` for browser flamegraphs.
- **`benchstat`** — compare two bench runs, surface statistically significant deltas. Without it, "5% faster" might be noise.
- **`go test -race`** — every concurrent perf change runs through it. A perf win with a race is a regression in disguise.

### TypeScript / Node
- **`--inspect` + Chrome DevTools Performance** — flamegraphs and call trees.
- **`clinic`** — `doctor` for diagnosis, `flame` for CPU, `bubbleprof` for async hotspots (event-loop blocking is the most common Node perf bug).
- **`node --prof` + `--prof-process`** — V8's built-in sampler, lower overhead than the inspector.
- **`autocannon` / `wrk` / `k6`** — load generation under realistic concurrency.

### Browser TypeScript
- **Chrome DevTools Performance** — long tasks, rendering tab, memory timeline. Most bugs: layout thrash, large React render trees, sync main-thread blocking.
- **React Profiler** — why X re-rendered.
- **Web Vitals** (`LCP`, `INP`, `CLS`) — optimize these, not raw JS execution.

## Percentiles, not averages

Always report **at least p50 and p99**. A change moving the mean 100→80ms while pushing p99 500ms→2s is a regression for every user past p99 — the tail is where users sit under stress and what takes services down.

- p50 — typical request. p95 — slightly bad day. p99 — properly bad day. p99.9 — worst affected; often the key number for capacity planning.

Means hide bimodality: 95% cache hits at 1ms + 5% misses at 200ms = mean ~11ms, p95 ~200ms. The mean is a fiction nobody experiences.

## Amdahl & triage

What fraction of wall-clock does this code account for? Doubling the speed of a 2% function buys 1%; the same effort on the 30% line buys 15%. Read the flamegraph from the widest bars; only touch what's load-bearing. Optimizing the 2% line because it's easy is procrastination disguised as work.

## Latency vs throughput

Separate axes; optimizing one can hurt the other.

- **Latency** — time for one request. Bound by serial dependencies, round trips, blocking primitives.
- **Throughput** — sustainable req/s. Bound by the slowest stage. Queue depth raises throughput AND latency.

p99-latency SLO → batching is your enemy past a point. Req/s SLO → batching is your friend. Pick the axis *before* optimizing.

## When to optimize vs leave alone

Optimize when: profiling shows hot path (≥5% of the cost you care about); the SLO is at risk now or at 3-month growth; the change is mechanical and the diff small (type change, pre-allocation, hoist).

Don't when: not on the hot path (pretty code at 0.01% is finished); the optimization fights the codebase's reading model; it's premature — the system isn't built, the access pattern unknown. Correct first; measure; optimize what hurts.

## Common false economies

- **`++i` vs `i++` in a `for` header.** Compilers fold both.
- **Tuple over list (Python) "for speed."** ns-range difference; pick by mutability.
- **`numpy` for a 10-element array.** Setup cost dominates; plain Python wins on tiny inputs.
- **Manual inlining "to skip the call."** Interpreters/compilers inline hot calls; manual inlining hurts readability.
- **`StringBuilder` / `bytes.Buffer` for two concatenations.** Overhead exceeds savings until ~10+.
- **`reflect` "carefully" in a Go hot path.** ~10× slower than direct access; codegen the marshaler.
- **Caching pure functions without a hit-rate measurement.** Fast function + low hit rate = the cache is a pessimization.

## System-level perf

Most production latency lives outside the hot loop:

- **Connection pool sizing.** Too small → serial bottleneck; too large → idle conns eat the upstream's slots. Sizing math in `resilience.md`. The wrong pool size is a bigger latency lever than any code change.
- **Queue depth and back-pressure.** A queue is buffered latency; unbounded queue = unbounded p99. Bound it and decide the full-queue behavior (drop, 429, slow producer).
- **Fanout and join.** N parallel sub-requests are bounded by the slowest: p50 of the slowest of 10 ≈ p99 of any one. Timeouts or hedged requests to bound the tail.
- **Cache locality.** Sequential beats random access 10–100×. SoA vs AoS matters in tight loops over many items.
- **Serialization cost.** JSON parse/serialize routinely dominates request CPU. Profile before assuming the "real work" is the cost center; msgpack/protobuf/simdjson often pay off at the boundary.
- **GC pressure.** Allocation per request × QPS = GC frequency. Pool/reuse on long-lived workers. Go: `GOGC`, `runtime/debug.SetMemoryLimit`. Python: fragmentation on long-running processes — recycle workers.

## Language-specific hot spots

### Python
- **The GIL.** CPU-bound work doesn't parallelize across threads. `multiprocessing` / `ProcessPool` / Rust-C extension. Free-threaded 3.13+ is changing this; default interpreter still has the GIL.
- **Event-loop blocking.** Sync calls (`time.sleep`, CPU-bound regex, `json.dumps` on a big object) inside `async` block every coroutine. `run_in_executor` / thread pool.
- **Comprehensions ~30% faster than `for`-append** (no per-call `append` attribute lookup). Comprehensions for builds; `for` for side effects.
- **`str` concatenation in loops is quadratic.** Accumulate to a list, `"".join()`.

### Go
- **Goroutine spawn is cheap, not free** (~µs). One per item in a 1M loop is wrong — worker pools.
- **Maps allocate.** `make(map[K]V, expectedSize)` avoids growth rehashing.
- **Interface conversions / reflection.** `interface{}` boxes; generics (1.18+) avoid it; reflection ~10× slower.
- **Escape analysis.** Pointer returns from short functions force heap allocation. `go build -gcflags="-m"` shows escapes. Large structs by pointer, small by value.

### TypeScript / Node
- **Event-loop blocking.** Sync CPU work (big JSON parse, sync crypto/regex) blocks every request. Worker thread or chunk with `setImmediate`.
- **Promise chain depth.** Each `await` is a microtask; deep chains inflate p99 via scheduling. Flatten.
- **Hidden library allocations.** `lodash.cloneDeep`, JSON round-trip clones, `Object.assign({}, ...)` in hot paths. Profile first.
- **React re-renders.** Inline object/array props cause child re-renders. `useMemo`/`useCallback` for hot trees — by Profiler, not guess.

## Benchmarking checklist

Before reporting a number:

- [ ] Warm-up run discarded (JIT / cache / pool init).
- [ ] ≥10 samples; report distribution, not mean alone.
- [ ] Same machine, load, time of day (or controlled environment).
- [ ] No other workloads on the host; disable turbo-boost if available.
- [ ] Statistical significance: `benchstat` (Go), `pytest-benchmark --benchmark-compare`, or change ≫ noise floor.
- [ ] Memory measured separately from CPU — many "faster" changes win CPU and lose allocations.
- [ ] Both p50 and p99 reported. Only the mean moved → not load-bearing.

A benchmark report without these is suspicious by default.
