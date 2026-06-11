# Performance

Open this when adding code to a hot path, when a service hits a latency or
throughput SLO, when a benchmark regresses, or when reviewing a diff motivated
by "make it faster." The `SKILL.md` principle *measure before optimizing* is the
one that survives all the others.

Complements (doesn't replace) the `Runtime optimization`, `CPU & memory
budget`, and `Memory` sections in `SKILL.md` — those say *what shapes are
wrong*; this says *how to find which one is actually costing you*.

## The iron rule

**No optimization without a measurement.** Tuning a `for` loop because it
"feels slow" is folklore; tuning a function the flamegraph shows at the top is
engineering. No before-and-after number → the change is theatre. This holds even
when "obviously" faster, because:

1. **The bottleneck is rarely where you think** — profilers surprise even
   experienced engineers (the 2% function you suspected, vs the logging call you
   forgot existed).
2. **Optimizations have hidden costs** — a faster algorithm that allocates more,
   breaks vectorization, or hurts cache locality can land slower in prod.
3. **Legibility is a budget** — clever that earned 3% is a 3% regression in the
   next maintainer's understanding. Pay for clever only when data demands it.

## The measurement loop

Five steps; skip one and you're guessing.

1. **Reproduce the symptom** — a benchmark, load test, or recorded request you
   can run repeatedly and that the change will move.
2. **Capture a baseline** — numbers, not impressions. p50, p95, p99, and
   throughput separately. One number is a lie of omission.
3. **Profile** — CPU profiler for CPU-bound, memory for memory, tracing for
   cross-service. Read the flamegraph before touching code.
4. **Change one thing.** Otherwise the post-change number tells you nothing
   about which change moved it.
5. **Re-measure** — same benchmark, load, machine state. Confirm the dial moved
   and nothing else regressed.

If steps 2 and 5 aren't comparable (different machine, load, warm state), the
experiment is invalid — start over.

## Profilers per language

**Python**
- **`py-spy`** — sampling, attach to a running process, low overhead. First
  reach for almost everything: `py-spy record -o flame.svg -- python -m my_service`.
  Works on prod with a brief SIGSTOP.
- **`cProfile`** — stdlib deterministic, higher overhead; offline single-script
  analysis. `python -m cProfile -o out.prof script.py` then `snakeviz out.prof`.
- **`tracemalloc`** — stdlib memory; allocation source lines + snapshot diffs.
  Leaks and per-request bloat.
- **`memray`** — sampling memory profiler with allocation-source flamegraphs;
  better signal than `tracemalloc` for hot allocators.
- **`pytest-benchmark`** — micro-benchmarks; pin the test, lock the baseline,
  run on CI to catch regressions.

**Go**
- **`go test -bench=. -benchmem -count=10`** — table stakes for a perf PR;
  without `-benchmem`, allocation regressions hide.
- **`pprof`** — `go tool pprof` against `/debug/pprof/profile` (CPU), `/heap`
  (alloc), `/goroutine`. `web` for a browser flamegraph.
- **`benchstat`** — compares two `-bench` runs and surfaces statistically
  significant deltas; without it "5% faster" might be noise.
- **`go test -race`** — not a profiler, but every concurrent perf change runs
  through it. A win that introduces a race is a regression in disguise.

**TypeScript / Node**
- **`--inspect` + Chrome DevTools Performance** — flamegraphs and call trees.
- **`clinic`** — `doctor` (diagnosis), `flame` (CPU), `bubbleprof` (async
  hotspots). The async one matters — event-loop blocking is the most common Node
  perf bug.
- **`node --prof` + `--prof-process`** — V8 sampling profiler, lower overhead
  than the inspector.
- **`autocannon` / `wrk` / `k6`** — load generation for HTTP perf under
  realistic concurrency.

**Browser TS**
- **Chrome DevTools Performance** — long tasks, rendering, memory timeline. Most
  bugs are layout thrash, large React render trees, or main-thread blocking.
- **React Profiler** — component re-render perf; why X re-rendered.
- **Web Vitals** (LCP, INP, CLS) — optimize these (map to user experience), not
  raw JS execution.

## Percentiles, not averages

The biggest signal lost to optimization-theatre is mean vs tail. Always report
**at least p50 and p99**. A change taking the mean 100→80 ms while pushing p99
500 ms→2 s is a regression for every user past p99 — and the tail is where real
users sit under stress, and where services go down.

- p50 — typical request. p95 — slightly bad day. p99 — properly bad day. p99.9 —
  worst affected (often the most important for capacity planning).

Means hide bimodality: 95% cache hits at 1 ms + 5% misses at 200 ms = ~11 ms
mean, ~200 ms p95 — the mean is a fiction nobody experiences.

## Amdahl & triage

Ask what fraction of wall-clock the code accounts for. A 2% function made twice
as fast = 1% faster request; the same effort on the 30% line = 15%. Read the
flamegraph top-down (widest bars), touch only what's load-bearing. Optimizing
the easy 2% line is procrastination disguised as work.

## Latency vs throughput

Two axes; optimizing one can hurt the other.

- **Latency** — time for one request. Bound by serial dependencies, round
  trips, blocking. Lower bound = longest chain of unavoidable serial work.
- **Throughput** — sustainable RPS. Bound by the slowest stage's capacity.
  Adding queue depth raises throughput *and* latency.

p99-latency SLO → batching is your enemy past a point. RPS SLO → batching is
your friend. Pick the axis *before* optimizing.

## When to optimize vs leave alone

**Optimize when:** profiling shows it's hot (≥5% of the cost you care about);
the budget is tight and the SLO is at risk now or at projected growth; the
change is mechanical and small (a type change, a pre-allocation, a hoist out of
a loop).

**Don't when:** it's not hot (pretty code at 0.01% of the budget is finished);
it fights the codebase (a micro-clever loop that breaks the team's reading model
is debt); it's premature (system not built, access pattern unknown — correct
first, measure, optimize what hurts).

## Common false economies

Folklore the compiler now handles, or that costs more than it saves:

- **`++i` vs `i++` in a `for` header** — compilers fold both; pick the readable
  one.
- **Tuple over list (Python) "for speed"** — ns-range difference; the wrong
  shape costs O(n) per traversal. Pick by mutability.
- **`numpy` for a 10-element array** — setup cost dominates; plain Python wins
  on tiny inputs.
- **Inlining "to skip the call"** — interpreters/compilers inline hot calls
  anyway; manual inlining hurts readability and future optimization.
- **`StringBuilder` / `bytes.Buffer` for two concatenations** — overhead exceeds
  savings until ~10+ concatenations.
- **`reflect` "carefully" in a hot path (Go)** — carefully isn't enough; ~10×
  slower than direct access. Codegen the marshaler.
- **Caching pure-function results without a hit-rate measurement** — a fast
  function with a low hit rate makes the cache a pessimization. Measure hit rate.

## System-level perf

Most production latency lives outside the hot loop — look upstream:

- **Pool sizing.** Too small → serial through a bottleneck; too large → idle
  connections eat the upstream's slot budget. (Sizing math in `resilience.md`.)
  Often a bigger lever than any code change.
- **Queue depth / back-pressure.** A queue is buffered latency; unbounded queue
  = unbounded p99. Bound it and decide the full action (drop, 429, slow
  producer).
- **Fanout and join.** N parallel sub-requests are bounded by the slowest, not
  the average — the p50 of the slowest of 10 is the p99 of any one. Bound the
  tail with timeouts or hedged requests.
- **Cache locality.** Sequential beats random by 10–100× on modern CPUs;
  structure-of-arrays vs array-of-structures matters in tight loops.
- **Serialization cost.** JSON parse/serialize routinely dominates request CPU.
  Profile before assuming the "real work" is the cost center; faster codecs
  (msgpack, protobuf, simdjson) pay off on the boundary.
- **GC pressure.** Allocations/request × QPS = GC frequency. Pool/reuse on
  long-lived workers. Go: watch `GOGC`, `runtime/debug.SetMemoryLimit`. Python:
  watch fragmentation on long-running processes — recycle workers.

## Language-specific hot spots

**Python**
- **The GIL.** CPU-bound work doesn't parallelize across threads in CPython —
  use `multiprocessing` / `ProcessPool`, or a Rust/C extension. Free-threaded
  3.13+ changes this, but the default interpreter still has the GIL.
- **Event-loop blocking in asyncio.** A sync call (`time.sleep`, CPU-bound
  regex, big `json.dumps`) inside `async` blocks every coroutine. Push to
  `run_in_executor` or a thread pool.
- **Comprehension vs `for`-append.** Comprehensions ~30% faster (no per-call
  `append` attribute lookup). Use them for builds, `for` for side effects.
- **`str` concat in loops.** Quadratic — accumulate to a list, `"".join()`.

**Go**
- **Goroutine spawn is cheap, not free** (~µs each). Per-item in a 1M loop is
  wrong — bound with worker pools.
- **Maps allocate.** `make(map[K]V, expectedSize)` pre-sizes to avoid growth
  rehashing — significant on hot paths.
- **Interface conversions / reflection.** `interface{}` boxes; generics
  (1.18+) avoid boxing for monomorphized cases; reflection ~10× slower.
- **GC and escape analysis.** Pointer returns from short functions force heap
  allocation. `go build -gcflags="-m"` shows escapes — large structs by pointer,
  small by value.

**TypeScript / Node**
- **Event-loop blocking.** Sync CPU work (JSON parse on a big string, sync
  crypto/regex) blocks every request — worker thread or chunk with
  `setImmediate`.
- **Promise chain depth.** Each `await` is a microtask; deep chains inflate p99
  via scheduling, not CPU. Flatten where possible.
- **Hidden library allocations.** `lodash.cloneDeep`, JSON round-trips for deep
  clone, `Object.assign({}, ...)` in hot paths — profile, don't assume "free."
- **React re-renders.** Inline object/array literals as props cause child
  re-renders; `useMemo`/`useCallback` for hot trees — profile, don't guess.

## Benchmarking checklist

Before reporting a number:

- [ ] Warm-up run discarded (JIT / cache / pool init).
- [ ] ≥10 samples; report the distribution, not the mean alone.
- [ ] Same machine, load, time of day (or controlled environment).
- [ ] No other host workloads; disable turbo-boost if available.
- [ ] Statistical significance: `benchstat` (Go), `pytest-benchmark
      --benchmark-compare`, or eyeball if the change dwarfs the noise floor.
- [ ] Memory measured separately from CPU — many "faster" changes win CPU, lose
      allocations.
- [ ] Both p50 and p99 reported. If only the mean moved, it's not load-bearing.

A report without these is suspicious by default.
