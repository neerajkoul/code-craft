# Observability — SLOs, alerting, RED/USE

Open when designing a service's SLOs, writing alerts, or auditing whether existing instrumentation answers the operational question. Complements `SKILL.md`'s *Production readiness* — that says *what to emit*; this says *what to do with it*.

## SLI / SLO / SLA — keep them straight

- **SLI (Indicator)** — a measurement. "Fraction of requests that completed in under 300ms." Always a ratio of `good_events / valid_events`.
- **SLO (Objective)** — the target for the SLI over a window. "99.5% of requests complete in under 300ms over a rolling 28 days."
- **SLA (Agreement)** — the contractual SLO with consequences (refund, credit). Usually looser than the internal SLO.

The internal SLO is **tighter than the SLA** so you notice degradation before customers can claim a credit.

## Picking SLIs — the four golden signals + RED + USE

Three overlapping frames; pick one consistent set per service type.

**Four Golden Signals (Google SRE):** latency, traffic, errors, saturation. Universal default.

**RED (request-oriented services):** Rate, Errors, Duration. The trio that matters for a service handling requests.

**USE (resource-oriented):** Utilization, Saturation, Errors. The trio for a resource (CPU, disk, pool). Pairs with RED — RED for the workload, USE for the resources it runs on.

Per service, write down:

| | What you measure | Example |
|---|---|---|
| Availability | `requests succeeded / requests valid` | `5xx + timeouts / total` |
| Latency | `requests under threshold / total` | `requests < 300ms / total` |
| Quality | `correct results / total` | recommendation relevance |
| Freshness | `data younger than X / total reads` | `reads of rows < 5min old` |

Two or three SLIs per service is right; ten is theatre.

## Setting the objective — the budget math

Error budget = `1 - SLO`. 99.9% SLO → 0.1% budget. Over 30 days: 43 minutes of full failure, or some equivalent partial. The budget is the currency of "how much can we break things to ship faster."

Sizing:

- **Below the historical baseline = pointless.** If you already do 99.99%, setting 99% just licenses regression.
- **Above what the architecture supports = aspirational.** Demanding 99.99% on a service with one replica and no leader election is fiction.
- **Customer-relevant.** The number must reflect what users actually feel. p99 latency matters more than p50 to the user at p99.

99.9% is the typical starting point for a tier-1 service. Three-nines means ~8h/year downtime; four-nines (99.99%) means ~52min/year and demands serious investment.

## Burn-rate alerting — the modern pattern

Old way: "alert if latency > X for 5 minutes." Noisy. Misses slow drift. Fires on transient blips.

**Multi-window multi-burn-rate alerts** (Google SRE Workbook, the standard since 2019):

- **Burn rate** = how fast you're consuming the error budget relative to the period. 1× burn = on track to use 100% in 30 days. 14.4× burn = on track to use 100% in 50 minutes.
- **Two windows per alert** — a long window (catches sustained drift) and a short window (confirms it's *current*, not historical). Both must trigger.
- **Multiple tiers** — fast alerts (page) for catastrophic burn, slower ones (ticket) for slow drift.

Standard four-tier setup (PagerDuty-style):

| Severity | Long window | Burn rate | Short window | Budget burned | Action |
|---|---|---|---|---|---|
| Critical | 1h | 14.4× | 5m | 2% in 1h | Page |
| High | 6h | 6× | 30m | 5% in 6h | Page |
| Medium | 24h | 3× | 2h | 10% in 24h | Ticket |
| Low | 72h | 1× | 6h | 10% in 72h | Ticket |

Prometheus example (latency SLO 99.5%):

```promql
# Fast burn: 14.4× over 1h, confirmed by 14.4× over 5m
(
  sum(rate(http_requests_total{status=~"5..|"}[1h])) /
  sum(rate(http_requests_total[1h]))
) > (14.4 * (1 - 0.995))
AND
(
  sum(rate(http_requests_total{status=~"5..|"}[5m])) /
  sum(rate(http_requests_total[5m]))
) > (14.4 * (1 - 0.995))
```

Why both windows: the 1h window without the 5m gate fires after the issue is over (lagging). The 5m window alone fires on transients (noisy). Together: fast and stable.

## Alert hygiene — page vs ticket

| Page when… | Ticket when… |
|---|---|
| Customer-visible right now | Trending wrong; not yet visible |
| Action required in < 5 minutes | Action can wait until business hours |
| Budget burning fast (critical/high tier) | Budget drifting (medium/low tier) |
| Cascading risk to other services | Localized, contained |

**Every page must be actionable.** If the on-call response is "investigate" with no runbook step, the alert is broken. Each alert links to a runbook covering: diagnosis, mitigation, escalation, when to declare incident.

**Every page must be silenceable in one click** when known. A page that fires for 4 hours of a deploy you knew about is training the team to ignore pages.

## Dashboards — the four-screen layout

For each service, one dashboard with four sections in this order:

1. **SLO status.** Current burn rate; budget remaining; trend over the window.
2. **RED.** Rate, errors, latency p50/p95/p99 — by route / handler.
3. **Saturation.** Pool utilization, queue depth, CPU/memory/GC.
4. **Upstream / downstream.** Calls out (latency / errors per dependency), calls in (per caller).

If the on-call can't answer "is this service healthy" in 30 seconds from this dashboard, it's the wrong dashboard.

## Logs, metrics, traces — when to use which

| Tool | Use for | Don't use for |
|---|---|---|
| **Structured logs** | Per-event detail: what happened, with which inputs (sanitized), at what time | Aggregation queries (slow), capacity planning |
| **Metrics** | Aggregations: counts, rates, histograms, gauges | Per-request detail (cardinality explosion) |
| **Traces** | Causal chain of a single request across services | Aggregate analysis (samples, not totals) |

Three rules:
- **Cardinality discipline on metrics.** Every label is a series. `tenant_id` as a label on a 100k-tenant system kills Prometheus. Use logs/traces for high-cardinality dimensions, metrics for low-cardinality (`route`, `error_kind`, `status_class`).
- **Trace context propagated everywhere.** W3C `traceparent` header on every cross-service call, message header, log line. Without it, traces don't stitch.
- **Logs and traces share correlation IDs.** A log line and a span for the same request can be joined by `trace_id` + `span_id`. If they can't, half your tools are blind.

## RED checklist per request handler

- [ ] Counter `requests_total{route, status_class}` — for rate + errors.
- [ ] Histogram `request_duration_seconds{route}` — for latency percentiles.
- [ ] Trace span per handler; child spans per outbound call.
- [ ] Structured log per request: trace_id, route, status, duration, tenant_id, user_id, error class.
- [ ] No PII / secrets / full bodies in logs.

## USE checklist per resource

- [ ] Utilization: % of time the resource was busy (CPU, pool slot in use, disk IO).
- [ ] Saturation: queue / wait time / pool wait events.
- [ ] Errors: failures attributable to the resource (`pool_acquire_timeout_total`, `disk_io_errors_total`).

## SLO review cadence

- **Weekly:** burn-rate trends, action items from any incident.
- **Monthly:** SLO target review. Did the budget hit zero? Why? Adjust targets, or shift work to reliability.
- **Quarterly:** SLI definitions. Are we measuring what the customer feels? Is anything missing (e.g., we measure latency but not freshness)?

A team that ships features for 30 consecutive days with zero budget burn has a too-loose SLO. A team that burns the budget every week has a too-tight one or a real reliability problem.

## Anti-pattern fingerprints

- Alert on a raw threshold (`latency > 500ms`) with no SLO link — fires forever during a known degradation. 🟡
- Alert with no runbook — on-call guesses. 🟡
- One window for the alert (no short-window gate) — lagging, noisy. 🟡
- High-cardinality label on a metric (`user_id`, `request_id`) — series explosion. 🔴 (memory, scale)
- Log lines without trace_id / correlation id — cross-service debugging blind. 🟡
- Mean latency tracked, no p99 — tail invisible. 🟡
- No SLO documented for a tier-1 service — no shared definition of "broken." 🟡
- `panic` / `error` log lines used as metrics (counted in an alert) — log volume drives alerts, not real signal. 🟡

## Checklist

- [ ] Service has 2–3 SLIs, each a `good/valid` ratio.
- [ ] SLO documented, with budget = `1 - SLO`.
- [ ] Multi-window multi-burn-rate alerts (≥ 2 tiers: page + ticket).
- [ ] Every page has a runbook link.
- [ ] RED metrics per route; USE metrics per pool/queue/CPU.
- [ ] Dashboard layout: SLO → RED → saturation → upstream/downstream.
- [ ] Trace context propagated across every boundary.
- [ ] Logs are structured, carry trace_id + tenant_id + request_id.
- [ ] No high-cardinality labels in metrics.
- [ ] Monthly SLO review on the calendar.
