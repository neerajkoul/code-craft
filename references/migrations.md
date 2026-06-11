# Migrations — schema, data, and rollout

Open when writing DDL, backfilling data, or rolling out any change that touches a populated table. The defining property: **migrations run while the application is running.** Old code and new code share the schema for the duration of the rollout. Most migration bugs come from skipping this.

## Iron rule: expand → migrate → contract

Never combine "add new shape" with "remove old shape" in one deploy. Three deploys, never fewer:

1. **Expand.** Add the new column / table / index. Both old and new code can read; only old code writes (or both write to both shapes — see below).
2. **Migrate.** Backfill old data into the new shape; switch readers to the new shape; dual-write if necessary.
3. **Contract.** Once nothing references the old shape, drop it.

Why three deploys: during a rolling deploy, two versions of the app run simultaneously. A migration that the old version doesn't understand crashes old pods; a column drop the new version still references crashes new pods. Expand-migrate-contract keeps both versions compatible at every step.

## Common DDL patterns and their traps

### Adding a column

- **Optional, nullable, no default:** safe and fast on Postgres (≥ 11) — metadata-only change. Safe on MySQL (≥ 8.0 instant ADD COLUMN) for compatible types.
- **With default:** Postgres ≥ 11 fast (metadata-only); earlier versions rewrite the table. MySQL: depends on storage engine and column type.
- **NOT NULL with no default:** rewrites the table; locks; old code can't insert (no value for the new column). **Three-step:**
  1. Add nullable.
  2. Backfill values; update writes to populate.
  3. Add `NOT NULL` constraint.

### Dropping a column

- **In code first.** Stop reading + writing the column in a deploy. Bake.
- **Then drop in DB.** Postgres / MySQL handle this fast.
- **Never the other way round.** Dropping in DB first crashes still-running old pods that reference the column.

### Renaming a column

There is no safe in-place rename across a rolling deploy. Pattern:

1. Add the new column.
2. Dual-write: new code writes to both old and new.
3. Backfill old → new.
4. Switch reads to new.
5. Stop writing the old column.
6. Drop the old column.

Five+ deploys. Often the rename isn't worth it — leave the old name as a comment or alias.

### Adding an index

- **`CREATE INDEX CONCURRENTLY` (Postgres).** Non-blocking. Required on populated tables. Failure leaves an INVALID index — drop and retry.
- **`pt-osc` / `gh-ost` (MySQL).** Online schema change tools that build the index on a shadow table. Standard at scale.
- **Lock-blocking `CREATE INDEX`** on a large table can stop writes for minutes. Almost always wrong in production.
- **Validate the plan changes.** A new index doesn't help unless the query planner uses it. `EXPLAIN ANALYZE` before and after; pin the plan in CI if it matters.

### Adding a foreign key

- `ALTER TABLE ... ADD FOREIGN KEY ... NOT VALID` (Postgres) — accepts new rows; doesn't scan existing.
- `ALTER TABLE ... VALIDATE CONSTRAINT` — separate step, doesn't take an exclusive lock on the referenced table.
- Done in two steps, FKs are safe on large tables. In one step, they lock for the duration of the scan.

### Tightening a check constraint

Same `NOT VALID` → `VALIDATE` pattern as FKs.

### Changing a column type

Always a full rewrite. Pattern: add new column with new type, dual-write, backfill, switch reads, drop old. Same five-step as rename.

## Backfills — make them safe

A naive `UPDATE big_table SET new_col = ...` locks the whole table.

**Right shape:** batch, throttle, observable.

```sql
DO $$
DECLARE
  last_id BIGINT := 0;
  batch_size INT := 10000;
BEGIN
  LOOP
    UPDATE big_table
      SET new_col = compute(old_col)
      WHERE id > last_id AND id <= last_id + batch_size
        AND new_col IS NULL;
    EXIT WHEN NOT FOUND;
    last_id := last_id + batch_size;
    PERFORM pg_sleep(0.1);  -- throttle
  END LOOP;
END $$;
```

Better: run from application code, not psql. Reasons:
- Observable: metrics on rows/sec, errors, ETA.
- Resumable: persist the cursor; restart picks up.
- Throttleable: react to replication lag / load (slow down when behind).
- Cancellable: kill it cleanly if needed.

**Backfill jobs are first-class deliverables.** Code reviewed, tested on a snapshot, runnable in stages.

### Backfill gotchas

- **Writes during the backfill must end up consistent.** Either the application writes to both shapes during the migration, or the backfill is idempotent and re-runs after the cutover for any rows that slipped through. CDC (`distributed.md`) makes this easier — the WAL captures every write.
- **Replication lag.** A high-volume UPDATE on the primary stresses replicas. Watch `pg_stat_replication` / equivalent; pause if lag grows.
- **Long-running transactions hold visibility maps open.** Postgres autovacuum can't clean tuples newer than the oldest open transaction. Backfill in many small transactions, not one giant one.

## Online schema-change tools

For MySQL: **`gh-ost`** (GitHub's, used at scale, replication-stream-based) or **`pt-online-schema-change`** (Percona, trigger-based). Both build a shadow table, copy data, swap. Necessary on large tables where any lock is unacceptable.

For Postgres: **`pg_repack`** for rebuilding tables; built-in `CREATE INDEX CONCURRENTLY` and `NOT VALID` constraints cover most cases without a separate tool. **`pgroll`** (Xata, 2024+) provides expand-migrate-contract as a first-class workflow with view-based zero-downtime semantics — useful for teams that want the discipline enforced by tooling.

## Migrations as code

- **Tool per language.** Liquibase / Flyway (JVM), Alembic (Python), `golang-migrate` / `goose` (Go), Drizzle / Prisma migrate (TS), Diesel (Rust).
- **Reversible where feasible.** Every migration has an `up` and a `down`. Drops and rewrites often can't be reversed losslessly — accept that and document.
- **Idempotent.** `CREATE TABLE IF NOT EXISTS`; `ADD COLUMN IF NOT EXISTS`. A migration that crashes halfway should re-run cleanly.
- **Versioned and ordered.** Timestamp-prefixed file names; the tool tracks applied state in a `schema_migrations` table.
- **Reviewed like code.** The PR description includes: what the migration does, lock implications, expected duration on the largest table, rollback plan.

## Pre-flight per migration

Before merging:

1. **Lock analysis.** Read the docs for your DB version. `ADD COLUMN ... NOT NULL DEFAULT` on Postgres 9.6 ≠ on Postgres 13. Know which lock level the operation takes.
2. **Estimated duration.** On the production-sized table, how long? Test on a recent snapshot or staging at scale.
3. **Replication impact.** A long DDL replicates; replicas catch up. Acceptable lag?
4. **Compatibility.** Does the old code crash with the new schema? Does the new code crash with the old schema? Both questions must be "no" during the rollout window.
5. **Rollback plan.** If this is wrong in prod, what's the fix? Sometimes "deploy forward" — the migration can't be reversed and the fix is a corrective migration. Say so up front.
6. **Backfill plan.** If data movement is needed, where does it run, how is it observable, when does it complete?

## Application-level discipline during rollout

- **Old + new code coexist.** Deploy the migration before the code that requires it. Old code stays compatible with the new schema.
- **Reads tolerate either shape during the window.** Optional columns; default values; alias readers.
- **Writes go to whichever shape is the source of truth.** During dual-write phases, both shapes get the same value, and a reconciliation job catches misses.

## Anti-patterns

- `ALTER TABLE ... ADD COLUMN NOT NULL DEFAULT ...` on a multi-million-row table in Postgres < 11 — table rewrite + exclusive lock. 🔴
- `CREATE INDEX` without `CONCURRENTLY` on a populated Postgres table — blocks writes. 🔴 (scale)
- Drop the column in the same deploy as the code that stops using it — old pods crash mid-rollout. 🔴
- Rename in one shot — old or new code breaks during rollout. 🔴
- Backfill in a single transaction — locks, replication lag, autovacuum starvation. 🔴 (scale)
- Migration not idempotent; rerun crashes — recovery from partial failure is impossible. 🟡
- No estimated duration / lock analysis in the PR — surprise outage. 🟡
- Backfill that doesn't account for in-flight writes — data corruption when concurrent writes land in the old shape. 🔴 (correctness)
- `down` migration drops data without `BEGIN`/`COMMIT` — partial rollback. 🔴

## Checklist (per migration PR)

- [ ] Expand → migrate → contract: which step is this PR? Other steps planned / scheduled.
- [ ] Lock analysis documented for the DB version in use.
- [ ] Estimated duration on production-sized table.
- [ ] `CREATE INDEX CONCURRENTLY` / `NOT VALID` + `VALIDATE` / online-schema-change tool used where applicable.
- [ ] Backfill plan: batched, throttled, observable, resumable.
- [ ] Old code + new schema compatible (read both shapes; write to canonical).
- [ ] New code + old schema compatible (until the migration runs).
- [ ] Reversible / corrective-fix plan named.
- [ ] CI ran the migration on a representative dataset.
