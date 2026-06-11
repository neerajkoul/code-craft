# Distributed systems

Open when code crosses a process boundary: queue consumer, retry, multi-service workflow, distributed lock, webhook, dual-write to DB+broker. Complements `resilience.md` (single-call timeouts/breakers/pools) — this is what to do when the call is part of a *workflow*.

## Core principles

1. **Assume at-least-once.** Every queue, webhook, retry, tool-call boundary delivers more than once. "Exactly-once" = at-least-once + consumer-side dedup. A claim without a named dedup mechanism is hand-waving.
2. **Dual writes are a bug.** `db.commit(); broker.publish()` lies on crash. Use CDC (preferred) or outbox. Never split.
3. **Idempotency is built, not assumed.** Every retryable write needs an idempotency key. `INSERT … ON CONFLICT DO NOTHING`, dedup tables keyed by message id, conditional CAS, natural keys `(tenant_id, external_id)`. "It's safe because we retry" is the bug.
4. **Distributed locks need fencing.** Lease + monotonic token, storage rejects stale tokens. Redlock without fencing isn't safe — a paused holder writes after lease expiry.
5. **Clocks lie.** Cross-node wall-clock comparisons are wrong for correctness. Use logical clocks, version columns, monotonic counters, or single source of truth.
6. **Order is not free.** Per-partition only. Cross-key ordering must be designed (single-flight per key, sequence numbers).
7. **Partial failure is default.** Any RPC can succeed on the server and fail on return. Caller cannot distinguish "didn't happen" from "happened, unknown." Recovery path required.
8. **Backpressure or die.** Producer > consumer + unbounded buffer = OOM. Bound it; pick a full-queue policy (drop / 429 / slow / DLQ).
9. **Compensations, not rollback.** Cross-service step can't `ROLLBACK`. Sagas need explicit compensating actions; compensations idempotent.
10. **Read-after-write isn't free.** Replicas and caches lag. Pin to primary, version the read, or design caller to tolerate staleness.

## Pre-flight — 6 questions

1. **Delivery guarantee at each hop?** Name it (at-most / at-least / dedup-based).
2. **Idempotency key per write?** Source (client > derived > generated), storage, TTL.
3. **Recovery path on partial failure?** Crash mid-workflow: replay → resume / re-exec / compensate?
4. **Ordering contract?** None / per-key / global. Who enforces (partition key, single consumer)?
5. **Concurrent writers to shared state?** None / lock+fence / CAS / sharded.
6. **Read consistency?** Strong / read-your-writes / eventual. Where does a stale read break an invariant?

## CDC over outbox — the dual-write fix

Both solve atomicity between DB and broker. CDC is preferred when the DB supports it.

**CDC (Change Data Capture).** A connector reads the DB's write-ahead log directly (Postgres logical replication, MySQL binlog, MongoDB change streams) and publishes to the broker. Debezium is the standard tool; Kafka Connect the standard host.

- No outbox table. No relay code. No extra write per request. No table to garbage-collect.
- Reads the WAL — exactly what the DB *actually* committed; cannot diverge.
- Lower latency than poll-based outbox; ms-range tail.
- Schema evolution handled at the connector layer (Debezium SMTs for filtering, routing, transforming).

**When CDC fits:**
- DB you control (Postgres ≥ 10, MySQL with binlog, MongoDB replica set, SQL Server with CDC enabled).
- Operations infra you can run (Kafka Connect cluster, or hosted: Confluent, Aiven, Striim, AWS DMS).
- Events derived from row state (`order.placed` ≈ "order row inserted"). Pure side-effect events that aren't row-shaped need shaping.

**When outbox still wins:**
- DB can't expose its log (SaaS DB, some serverless setups).
- Event semantics diverge sharply from row state — multiple events per write, or events with no row backing.
- Tiny scale where running Kafka Connect is overkill.

**CDC pattern:**

```sql
-- Postgres: enable logical replication
ALTER SYSTEM SET wal_level = logical;
CREATE PUBLICATION orders_pub FOR TABLE orders, payments;
```

Debezium reads the publication, publishes one event per row change to Kafka topics. Consumer-side dedup via `event_id` (Debezium provides `source.lsn` / `source.ts_ms` — monotonic) covers redelivery.

**Operational must-haves:**
- **Replication slot monitoring.** A stuck consumer holds the slot; WAL piles up; DB disk fills. Alert on slot lag.
- **Schema registry.** Avro/protobuf with a registry (Confluent, Apicurio). Schema changes flow through the registry; consumers see typed payloads.
- **Snapshot strategy.** Initial sync of existing rows. Debezium's incremental snapshot lets you re-snapshot without stopping.
- **DLQ + replay.** Bad event handlers go to a DLQ topic; operator surface to inspect and replay.

## Inbox pattern (consumer-side dedup)

Independent of CDC vs outbox. Write the incoming event id into a dedup table inside the same transaction as the side effect.

```sql
BEGIN;
INSERT INTO inbox_processed (event_id, processed_at)
  VALUES ($1, NOW()) ON CONFLICT DO NOTHING;
-- rowcount 0 → already processed; abort and ack
-- rowcount 1 → do the work
COMMIT;
```

TTL the inbox table beyond the broker's max redelivery window (7d safe).

## Idempotency key sources — best to worst

1. **Client-provided** (`Idempotency-Key` header, message `event_id`, webhook `delivery_id`). The producer knows when it's retrying.
2. **Derived from canonical request content** (hash of normalized body, `(tenant_id, external_ref)`).
3. **Server-generated at first sight, returned for follow-up.**
4. **None** — every retry is a new request. Wrong everywhere accepted.

Dedup window: max retry interval × safety factor. Webhooks → 7d. Queue redelivery → 7d. Synchronous → 24h.

## Ordering — what each broker gives

| Broker | Guarantee |
|---|---|
| Kafka | Per-partition (partition key = entity you need ordered) |
| NATS JetStream | Per-subject |
| RabbitMQ | Per-queue with `prefetch=1`; parallel consumers reorder |
| SQS standard | None |
| SQS FIFO | Per `MessageGroupId` |
| Pub/Sub | Per `orderingKey` (must enable) |

Parallel consumers on the same key reorder. Retries reorder (A fails, B succeeds, A retried). For correctness ordering: single-flight per key (one in-flight per partition key), or sequence numbers checked at the sink.

## Fencing tokens — the lock fix

The zombie-holder problem: lease expires during a GC pause; another acquirer takes the lease; both write. Any TTL can be exceeded by some pause. Fix:

```
Acquire lease → coordinator returns monotonic token T.
Every protected write carries T.
Storage: WHERE current_token < $T (else reject).
```

- **Token must be monotonic across acquirers.** etcd revision, ZooKeeper zxid, Postgres sequence, Kubernetes lease `resourceVersion`. Random UUIDs don't work.
- **Storage enforces.** If storage can't check, the lock is for performance only, not correctness.
- **Token propagates** through every hop in the call chain.

Don't roll leader election. Use etcd / ZooKeeper / Consul / k8s lease.

## Sagas — multi-step workflows

Cross-service workflow with N writes can't share a transaction. Saga = sequence of local transactions, each with a compensating action.

- **Orchestrated** (recommended for clarity): a coordinator (Temporal, Cadence, Step Functions, durable-function pattern) runs the steps and triggers compensations on failure.
- **Choreographed**: each service emits events; the next service listens. Hard to reason about at >3 steps.

Rules:
- Every step has a compensation. Compensations idempotent.
- Workflow state persisted between steps (replay-safe from any step).
- Idempotency at both the workflow layer (`if state.step >= event.step: return`) and the step layer (idempotency key on the side effect).
- Timeouts per step; total wall-clock deadline.

## Anti-pattern fingerprints

- `db.commit(); broker.publish()` — dual write. Use CDC. 🔴
- Retry loop on non-idempotent write — duplicate side effects. 🔴
- `SELECT … FOR UPDATE` held across a network call — pool drains. 🔴 (concurrency, scale)
- Redis `SETNX` lock with no fencing — zombie writer. 🔴
- `time.time()` / `Date.now()` cross-node comparison — clock skew. 🔴
- Webhook handler: no signature, no replay window. 🔴 (security)
- At-least-once consumer with side effects, no dedup table — N-fold side effects. 🔴
- Multi-service workflow with no per-step persistence — half-done state on crash. 🔴
- Unbounded fanout (goroutine/task per item) across the network — FD exhaustion. 🔴 (scale)
- "Exactly-once" in design with no named dedup — claim without proof. 🔴
- DLQ that drops on full — silent data loss. 🔴
- Global sequence via `uuid4` — UUIDs aren't ordered. 🔴

## Checklist

- [ ] CDC (or outbox) for every DB-then-publish flow.
- [ ] Every consumer idempotent (inbox table or natural dedup).
- [ ] Idempotency window > max redelivery × safety factor.
- [ ] Distributed locks have lease + fencing token + storage enforcement.
- [ ] Leader election via real coordinator.
- [ ] No cross-node timestamp comparison for correctness.
- [ ] Ordering requirement named; partition/group key matches.
- [ ] DLQ configured with max-retries, alerts, replay tooling.
- [ ] Bounded buffers; full-queue policy named.
- [ ] Trace context propagated via headers (`traceparent`).
- [ ] Tests: dup delivery → 1 side effect; lease expiry mid-op safe; crash mid-saga safe.
