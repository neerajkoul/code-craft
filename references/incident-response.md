# Incident response

Open when on call, when reviewing a postmortem, or when designing the operational surface of a service. Code in production fails; the discipline is responding fast, limiting damage, and learning. This reference is the loop.

## The phases — DETECT → DECIDE → MITIGATE → RESTORE → LEARN

1. **Detect.** A signal — alert, customer report, internal dashboard, deploy alarm.
2. **Decide.** Is this an incident? At what severity?
3. **Mitigate.** Stop the bleeding. Restoring is secondary to limiting blast radius.
4. **Restore.** Bring the system back to healthy.
5. **Learn.** Blameless postmortem, action items with owners and dates.

The mistake is collapsing Mitigate and Restore. Rolling back a deploy is mitigation; finding the root cause is restoration. Do mitigation first.

## Severity — name it in the first 5 minutes

Pre-agreed scale, public to the team. Sample:

| Sev | Criterion | Response |
|---|---|---|
| **SEV-1** | Major customer impact, data loss, or security breach | Page on-call, declare incident, dedicated channel, comms to customers within 30min |
| **SEV-2** | Significant impact to a subset; degraded but not down | Page on-call, dedicated channel, no customer comms unless escalates |
| **SEV-3** | Minor impact; workarounds exist; can wait business hours | Ticket; assigned in standup |
| **SEV-4** | No customer impact; internal alert | Ticket |

A SEV-1 needs an incident commander (IC), a comms lead, and an operations lead. For SEV-3 / SEV-4, the on-call covers all three.

## Roles during an incident

- **Incident Commander (IC).** Coordinates. Does *not* fix. Tracks timeline, drives decisions, knows who's doing what. The IC has the authority to declare, escalate, and stand down.
- **Operations lead.** The hands on keyboard. Investigates, mitigates, restores.
- **Comms lead.** Talks to customers, internal stakeholders, status page. Translates engineer-speak to user-impact.
- **Scribe** (optional, for long incidents). Records the timeline.

For SEV-1, these are different people. One person doing all four = chaos.

## Mitigation moves — try cheap, broad, reversible first

In rough order, before deep investigation:

1. **Roll back the last deploy.** ~80% of incidents are caused by a recent change. Cheap, reversible. Do this before debugging.
2. **Flip the kill switch / feature flag.** If a flag was rolled out, revert to 0%. See `feature-flags.md`.
3. **Failover / drain the bad region or instance.** Cut traffic from the affected pod / AZ / region.
4. **Scale up.** Sometimes the problem is load — more replicas, bigger nodes. Cheap and fast.
5. **Restart.** Last resort among "reversible" moves — it loses observability state but often clears transient stuck states.
6. **Throttle / shed load.** Reject lowest-priority traffic to protect the rest.

Investigation comes after mitigation. The bleeding stops first.

## Blast-radius limiting (design-time, not at incident time)

Decisions made before the incident determine how bad it gets:

- **Per-tenant rate limits and quotas.** One tenant's bug can't take down the rest.
- **Per-route concurrency caps.** Slow endpoint can't drain the pool for fast endpoints.
- **Bulkheads.** Separate pools per dependency / per priority. One sick downstream doesn't cascade.
- **Circuit breakers.** Fail fast; stop retrying the dead. See `resilience.md`.
- **Backpressure.** Bounded queues; full → reject. Unbounded = OOM cascade.
- **Per-region isolation.** A bug deployed to region A doesn't fail region B.
- **Per-tenant feature flags.** Roll out to canary tenants first.
- **Read replicas absorb reads** while the primary takes the write hit. The dashboard you load during an incident shouldn't ping the system in trouble.

## Live debugging — what to look at, in order

1. **The dashboard.** SLO + RED + saturation + upstream/downstream (see `observability.md`). Look for the deviation, not the absolute number.
2. **The deploy log.** What changed in the last hour / day? `gh pr list --search "merged:>$(date -v-1d)"`. Roll the deploy back before going deeper if it's plausibly related.
3. **The trace.** Pick a slow / failing request; follow the span chain. Where does latency land? What error fires first (upstream of the visible failure)?
4. **The logs.** `error` and `warn` level, last 15 minutes. Filter by trace_id from the bad request.
5. **The dependency.** Is downstream X healthy on its own dashboard? Often the bug is two services over.
6. **The infra.** Pod restarts, OOMs, network errors, disk fills. `kubectl events`, cloud provider's status page.

Time pressure makes people skip 1 and 2 and dive into logs. Resist. The dashboard tells you *where* faster than logs tell you *what*.

## Communication during the incident

- **Status page updated within 10 minutes** of SEV-1 declaration. "We are investigating reports of X. Updates every 30 minutes." Saying nothing is worse than saying "investigating."
- **Updates on a schedule** even when there's nothing new. "Still investigating, next update in 30min" is information.
- **No speculation in customer comms.** "Database issue" when you're not sure → eat the words later. "A degradation in our system" until you know.
- **Engineer-language stays internal.** A `panic: nil pointer dereference` in the customer status is unprofessional and unhelpful.

## Declaring resolved

- **Mitigation is in place.** Customer impact gone or below SLO threshold.
- **Monitoring confirms.** Not "we think it's fixed" — the dashboard agrees.
- **One full burn-rate window passes clean.** A 5-minute clean window after an SEV-1 isn't enough; an hour is.
- **Comms posted.** Status page updated to resolved.
- **Followups scheduled.** Postmortem owner named, draft due date set.

## Blameless postmortem template

The point: **prevent recurrence**, not find someone to blame. People make decisions that look reasonable with the information they had. The system and process is what failed.

Template (one document per SEV-1 / SEV-2; SEV-3 if there are systemic learnings):

```
# Postmortem: <title>

**Date:** YYYY-MM-DD
**Severity:** SEV-N
**Duration:** start → resolved (HH:MM)
**Author:** <name>      **IC:** <name>      **Status:** draft / final

## Summary
2–3 sentences. What broke, who was affected, how long.

## Impact
- Customer-facing: <N requests failed | N customers affected | feature X unavailable>
- Internal: <revenue, SLA exposure, downstream impact>
- SLO: <budget consumed for the month>

## Timeline (UTC)
- HH:MM — Deploy of #1234 to prod
- HH:MM — Error rate climbs above 5% on /api/orders
- HH:MM — Alert fires; on-call paged
- HH:MM — IC declares SEV-1; #incident-foo opened
- HH:MM — Rollback to previous version initiated
- HH:MM — Error rate normalises
- HH:MM — Resolved

## Root cause
The technical mechanism. One paragraph. Code-level when possible.

## Contributing factors
2–5 systemic causes, framed blameless:
- The reviewer was on PTO; review fell through.
- The test suite did not include this combination of inputs.
- The alert lagged the symptom by 20 minutes (long window only).
- The runbook for this service is 6 months stale.
- The kill switch existed but was undocumented and unused.

## What went well
What we want to keep doing:
- Page fired within 4 minutes of customer impact.
- Rollback procedure took 90 seconds.
- Status page updated within 8 minutes.

## What went poorly
What we want to fix:
- Initial diagnosis chased a logs-volume red herring for 15 minutes.
- The on-call didn't know about feature flag X.
- Customer comms delayed past the first 30 minutes.

## Action items
| # | Action | Type | Owner | Due | Issue |
|---|---|---|---|---|---|
| 1 | Add short-window gate to alert Y | preventative | @alex | 2026-06-25 | #1234 |
| 2 | Document kill switch X in runbook | mitigative | @sam | 2026-06-18 | #1235 |
| 3 | Add input-combination test case | preventative | @lee | 2026-06-30 | #1236 |
| 4 | Backfill the 200 affected orders | mitigative | @alex | 2026-06-12 | #1237 |

Every action item has: owner (one person, not "the team"), due date, tracking issue. No "investigate further" or "consider improving" — those aren't actions.

## Lessons learned
1–3 sentences each. Generalizable lessons, not specifics. "Alerts without a short-window gate fire after the fact; default to multi-window everywhere."
```

## Postmortem disciplines

- **Blameless.** Names appear in the timeline (actions taken), not in the contributing factors (system gaps). "Engineer pushed deploy" is the action; "deploy was reviewed only by one person on a Friday afternoon" is the system gap.
- **Action items have owners and dates** or they don't exist. Track to completion; revisit weekly.
- **Distinguish preventative from mitigative.** Mitigative fixes the immediate gap; preventative addresses the class of failure. Both required.
- **Publish broadly.** Postmortems are learning artifacts. Other teams should read them.
- **Revisit at 30 days.** Action items closed? If not, why not? Defer or reprioritize; never silent drop.

## Anti-pattern fingerprints

- IC also doing the fix on a SEV-1 — coordination collapses. 🔴
- Mitigation skipped to go straight to root cause — bleeding continues. 🔴
- Action items without owners / dates — won't happen. 🔴
- Postmortem singles out an engineer ("X should have caught this") — psychological-safety break, repeat incidents become hidden. 🔴
- Status page silent for > 30min on SEV-1 — customer trust crater. 🟡
- No kill switch / feature flag for the new feature — only fix is to deploy or roll back. 🟡
- Rollback procedure untested in the last quarter — first try during an incident is too late. 🟡

## Checklist (drill in calm times)

- [ ] Every service has documented severity criteria and on-call rotation.
- [ ] Every alert has a runbook link.
- [ ] Rollback / kill switch tested in the last 30 days.
- [ ] Status page automation tested.
- [ ] Postmortem template checked in; one open per recent SEV-1.
- [ ] 30-day action-item review on the calendar.
- [ ] On-call training: every engineer has shadowed an incident before primary on-call.
