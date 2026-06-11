# Caching

Open when adding, modifying, or auditing a cache — in-process LRU, Redis/Memcached, HTTP cache, CDN. Caches are a performance lever and a correctness foot-gun. The bugs they cause (stampedes, stale reads, invalidation storms) are the most common reason "the cache made things worse."

## Three questions before the cache

1. **What is the consistency requirement?** Strong / read-your-writes / eventual / "stale is fine for N minutes." Match the cache to it. Strong consistency + cache = surgical pattern; eventual consistency + cache = the easy case.
2. **What's the hit rate going to be?** Cache only pays off above ~70% hit rate. Below that, you're adding latency (the lookup) without the benefit. *Measure* it; don't assume.
3. **What's the invalidation strategy?** TTL? Write-through? Explicit invalidate? Each has known failure modes (below). "We'll figure it out later" = caching bug in production.

## Cache topologies

| Topology | When to use |
|---|---|
| **In-process LRU** | Single instance OK; tiny data; reads dominate. `functools.lru_cache`, `lru` crate, `lru-cache` npm. |
| **Local cache + invalidation channel** | Multi-instance, eventual consistency OK; broadcast invalidations via pub/sub. |
| **Distributed cache (Redis / Memcached)** | Shared across instances; data > one process can hold; consistency easier. |
| **HTTP / CDN cache** | Read-heavy public traffic; URL-shaped keys; cache headers control TTL. |
| **DB query cache (built-in / materialized view)** | Recompute expensive on write rather than read; trade write cost for read latency. |

Don't stack cleverly. One cache layer per call path; reasoning grows quadratic with layers.

## Cache stampede (thundering herd)

**The bug:** a hot key expires. The first request misses; before it finishes the recompute, N more requests miss. All N stampede the backend simultaneously. Database falls over from `N × expensive_query`.

Three combinable fixes:

### 1. Singleflight / request coalescing

The first miss starts the recompute; concurrent misses *wait on that one* instead of starting their own.

- Go: `golang.org/x/sync/singleflight`. Production-tested.
- Python: roll your own with an `asyncio.Event` per key, or `aiocache.cached(...)` which has it built in. A dict-of-locks per key works.
- Node: `dataloader` (per-event-loop coalescing), or `p-memoize` with `cachePromiseRejection: false`.

```go
var sf singleflight.Group
result, err, _ := sf.Do("key:"+k, func() (any, error) {
    return fetchExpensive(k)  // only one goroutine runs this at a time per key
})
```

Single-process coalescing covers the in-process case. For multi-instance, the herd still hits the cache+backend per process — combine with TTL jitter and probabilistic refresh below.

### 2. Probabilistic early expiration (XFetch)

Before TTL expires, each reader independently decides with rising probability to refresh proactively. Smooths the stampede across time.

Algorithm (per the canonical XFetch paper):
```
value, ttl, delta := cache.Get(key)
if now - delta*beta*ln(random()) >= ttl_expires {
    value = recompute()
    cache.Set(key, value, ttl)
}
return value
```

- `delta` = how long the recompute typically takes (observed).
- `beta` = aggressiveness; 1.0 is the standard default. Higher = refresh sooner.
- `random()` is in (0, 1].

Effect: as `now` approaches `ttl_expires`, the probability of an early refresh rises. The hot key gets refreshed *before* the cliff. Demonstrated to cut DB queries from 10k → 3–5 under 10k concurrent readers (Symfony's implementation reference).

Implementations: Symfony Cache (PHP), bundled in Redis client libraries, or a 20-line wrapper in any language.

### 3. TTL jitter

A million keys cached at the same instant (e.g., warm-up after a deploy) all expire simultaneously, all stampede simultaneously. Fix: add random jitter to TTLs at write time.

```python
ttl = base_ttl + random.uniform(-base_ttl * 0.1, base_ttl * 0.1)  # ±10%
cache.set(key, value, ttl)
```

Cheap, universal. Apply by default; combines with the patterns above.

### Combined recipe (high-traffic hot keys)

singleflight (per-process coalescing) + XFetch (cross-process pre-expiry refresh) + TTL jitter (avoid synchronized expirations) + monitoring (hit rate, recompute latency, stampede metric).

A distributed lock around recompute is *also* an option but the worst of the four — adds Redis round-trips to every miss, has its own contention failure modes, and singleflight already covers most of the win.

## Invalidation strategies

| Strategy | How | Trade-off |
|---|---|---|
| **TTL-only** | Set TTL; let it expire | Simple. Reads serve stale data for up to TTL after writes. Pick TTL = max tolerable staleness. |
| **Write-through** | Write to DB and cache atomically | Cache and DB in sync (mostly). Two writes per update; cache write can fail and leave inconsistency. |
| **Write-back** | Write to cache only; flush to DB later | Fast writes; data loss on cache failure. Rare in correctness-sensitive paths. |
| **Cache-aside (read-through)** | Read: check cache, miss → DB → populate cache | Default. TTL + invalidate on write covers most cases. |
| **Explicit invalidate** | On write, delete the key (let next read repopulate) | Simple. Risk: between delete and repopulate, a reader populates with stale data from a replica (the next pattern fixes). |
| **Write-through + version key** | Bump a version number on write; cache key includes it | Old keys become unreachable, fresh ones populate. No invalidation race. |

**The double-delete pattern (Reddit-famous bug):** Reader fetches stale → writer deletes cache → writer updates DB → reader populates cache with stale data from before. Fix: invalidate *after* the write, then *again* after a short delay (covers the in-flight reader). Or use version keys.

**TTL is your friend even with explicit invalidation.** Belt and suspenders: invalidate explicitly, but keep a TTL as backstop in case an invalidation event is lost.

## Negative caching

Cache the *absence* of data, not just the presence.

```
result = cache.get(key)
if result is NOT_FOUND_SENTINEL:
    return None
if result is None:
    result = db.fetch(key)
    if result is None:
        cache.set(key, NOT_FOUND_SENTINEL, ttl=60)  # short TTL
    else:
        cache.set(key, result, ttl=3600)
return result
```

Why: a 404-storm (attackers probing for resources, scrapers, broken client retrying a 404) hits the DB on every request. Negative caching turns it into a cache hit.

- **Short TTL** for negatives (60s typical). The resource may exist soon; you don't want to lie too long.
- **Don't negative-cache permission denials** as `NOT_FOUND` — leaks information about which keys exist by TTL difference.

## Read-your-writes with a cache

The classic violation: write to DB, return success to user, user reads back, hits the cache, sees the *old* value.

Fixes:

- **Invalidate on write** (above) — works if the user's next read happens after the invalidation propagates.
- **Read-after-write skip-cache window.** For N seconds after a user's write, their reads bypass cache (track via session cookie / request header). Simplest; common in social feeds.
- **Version token.** Write returns a version (`ETag`, `version: 42`). Read sends it. Cache only serves entries ≥ that version; below, refetch.
- **Pin to primary.** Skip cache + skip replica for the consistency window. Highest correctness, lowest perf gain.

## Cache key design

- **Include every dimension that varies the result.** `user_profile:{user_id}:{locale}:{plan_tier}` if any of those changes the answer. Missing a dimension = serving wrong data.
- **Namespace by version.** `v3:user_profile:{user_id}`. Bump the prefix when the schema or computation changes — old keys age out via TTL; you don't need a sweep.
- **Hash long keys** to avoid hitting the cache's key-length limit, but log the original for debuggability.
- **Don't put PII / secrets in keys.** Keys are visible in Redis `KEYS`, in logs, in dumps.

## Bounded memory

Every in-process cache has a max size and an eviction policy. Unbounded `dict[user_id] = profile` is an OOM under enumeration or one bad bot.

- LRU (most common), LFU, ARC, TinyLFU (Caffeine-style, best hit rate under skewed access).
- Monitor: hit rate, eviction rate, current size. A 100% hit rate with high eviction = the cache is too small.

## Observability for caches

Required metrics:

- `cache_hits_total{key_class}` / `cache_misses_total{key_class}` → hit rate per class.
- `cache_recompute_duration_seconds` → recompute cost; informs `delta` for XFetch.
- `cache_evictions_total` → sizing signal.
- `cache_stampede_coalesced_total` → singleflight effectiveness.
- For Redis: latency, memory used, ops/sec, keyspace hit rate (`INFO stats`).

A cache without these metrics is a black box. The first sign of a bug is "the DB is on fire" — too late.

## Anti-pattern fingerprints

- Cache around a query with no measured hit rate — the cache may be a pessimization. 🟢 (perf)
- No stampede protection on a hot key — DB falls over on first cache miss after a deploy. 🔴 (scale)
- Synchronized TTLs (no jitter) — fleet-wide stampede every TTL period. 🔴 (scale)
- Invalidation by delete only, with no version key, on a read-heavy keyspace — double-delete race. 🟡 (correctness)
- Cache key missing a dimension that varies the result — wrong data served. 🔴 (correctness)
- Distributed lock per recompute (no singleflight) — adds round-trips on every miss. 🟡 (perf)
- Unbounded in-process cache — OOM under enumeration. 🔴 (memory)
- Negative cache TTL = positive cache TTL — long-lived false negatives. 🟡 (correctness)
- Cache stores secrets / PII; key dumps leak it. 🔴 (security)
- HTTP cache without `Vary` header on a dimension that varies (locale, auth) — wrong cache hits across users. 🔴 (security, correctness)

## Checklist

- [ ] Hit rate measured before declaring "cache helps."
- [ ] Stampede protection: singleflight + XFetch (or equivalent) for hot keys.
- [ ] TTL jitter (±10%) by default.
- [ ] Invalidation strategy named and matches consistency requirement.
- [ ] Cache key includes every result-affecting dimension; namespaced by version.
- [ ] Read-your-writes handled (skip-cache window or version token) if user-visible.
- [ ] In-process caches have max size and eviction policy.
- [ ] Negative caching for 404-prone paths, short TTL.
- [ ] Metrics: hit/miss rate, recompute duration, evictions, stampede coalescing.
- [ ] No PII / secrets in keys; HTTP caches have correct `Vary`.
