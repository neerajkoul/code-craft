# Feature flags

Open when adding, removing, or auditing a feature flag — gradual rollout, kill switch, A/B experiment, ops control, permission gate. Flags are a deploy-safety primitive *and* a debt accumulator. Discipline: every flag has a type, an owner, and an expiration.

## The five flag types — pick one per flag

| Type | Purpose | Lifetime | Default |
|---|---|---|---|
| **Release** | Decouple deploy from launch; gradual rollout (1% → 10% → 50% → 100%) | Days–weeks; deleted after full rollout | Off (until rollout starts) |
| **Experiment** | A/B test; statistical comparison of two paths | Weeks–months; deleted after decision | Split per assignment |
| **Ops** | Operator control: rate-limit knobs, timeouts, queue sizes — change without deploy | Long-lived; reviewed quarterly | Sensible production value |
| **Permission** | Entitlement: feature available to paying tier, region, role | Permanent (becomes the entitlement model) | Off |
| **Kill switch** | Disable a feature instantly when it misbehaves | Permanent for high-blast-radius features | On (feature enabled by default) |

A flag without a type is debt by default. Force a type on creation.

## Kill switch — the most critical type

A kill switch is the "stop digging" tool when a feature misbehaves. It must work *while* the system is on fire.

Requirements:

- **Evaluates instantly with no remote calls.** A kill switch that depends on the broken downstream is useless. Cache evaluations in-process; refresh in the background.
- **Defaults to safe.** Fail-closed: if the flag service is down, the feature is *off*. Code branches: `if not flag.is_on("feature_x", default=False): use_safe_path()`.
- **Toggleable by on-call without a deploy.** A kill switch you must redeploy to flip is not a kill switch.
- **Documented in the runbook.** "If error rate on /api/orders > 5%: flip `orders_v2_enabled` to off in <flag UI>."
- **Tested.** A kill switch flipped for the first time during an incident is a coin flip.

Build kill switches for: every newly-launched user-visible feature, expensive backend changes (new DB path, new external dep), any feature where customer-visible failure would be SEV-2+.

## Automated kill — the safety net above the manual switch

For high-stakes flags, automate the flip on signal:

- **Trigger conditions:** error rate > X%, latency p99 > Y, downstream error rate > Z, budget burn rate > N.
- **Window:** 5–10 minutes sustained breach (not transient).
- **Action:** auto-flip to 0% and page on-call.
- **Confirmation required to re-enable** (humans only; no auto-recovery).

The pattern: flag service watches the SLI; flips when bad. Most managed flag tools (LaunchDarkly, Statsig, Optimizely, Flagsmith) support this directly.

## Gradual rollout — the rollout ladder

Standard ladder:

```
0%  → 1%  → 5%  → 25%  → 50%  → 100%
```

Each step: at least one observation window (1h–24h depending on traffic), watching SLIs. Promote if green; rollback if red.

Targeting strategies:

- **Random by hash of user_id.** Default; uniform sampling.
- **Internal employees first** (0% public; 100% staff). Catches obvious bugs before any customer sees them.
- **Canary tenants.** A handful of low-risk customers opt-in to early features.
- **By region / by version.** Roll out in `us-east-1` first; bake; expand.
- **Sticky targeting.** A user who's in the variant stays in it (don't flip mid-session).

Anti-pattern: jumping from 5% → 100%. The whole point of the ladder is to bound blast radius — skipping rungs collapses it.

## Targeting rules — keep them simple

Every targeting rule is logic the on-call must reason about during an incident. Three rules common; ten is a mystery box.

Good shapes:

- `if user_id in canary_list: on`
- `if hash(user_id) % 100 < rollout_pct: on`
- `if tenant.plan == "enterprise" and feature.gated: on`

Bad shapes:

- Cascading rules with priority order that's not documented.
- Targeting based on transient state ("active in the last 5 min") — flag flips per request.
- Targeting based on data that's not in the evaluation context (the flag must call out to fetch it = slow + failure-prone).

## Separation of concerns

Flag check stays out of business logic. The wrong shape:

```python
def calculate_total(order):
    if flag.is_on("new_pricing"):
        return new_pricing(order)
    return old_pricing(order)
# Now `calculate_total` knows about the flag forever; every test stubs it.
```

The right shape: thin wrapper at the seam.

```python
def calculate_total(order):
    pricer = pricing_strategy_for(order)  # picks the implementation
    return pricer.compute(order)

def pricing_strategy_for(order):
    if flag.is_on("new_pricing", user=order.user):
        return NewPricingStrategy()
    return OldPricingStrategy()
```

Business logic doesn't import the flag library. Cleanup later removes one wrapper, not surgery across every callsite.

## Flag debt — the long tail

Every flag that should be removed and isn't is a path that *might* execute. Old flags fire on weird inputs in production for years. The dead code never gets refactored because "the flag still references it."

Disciplines:

- **Expiration date at creation.** Release and experiment flags get a calendar date — 30/60/90 days typical. After that, the flag is debt.
- **Owner per flag.** One human (not "the team"). Owner gets pinged when the flag expires.
- **Quarterly audit.** Query the flag service for: flags older than 90 days, flags at 100% (release flags — done, remove), flags at 0% (canary'd and abandoned — remove), flags with no traffic (stale).
- **CI lint.** A linter scans the codebase for flag references; cross-references with the flag service's "expired" list; fails the build if any expired flag is still referenced.
- **Cleanup is its own PR.** Don't bundle "remove old flag" with "ship new feature." The cleanup PR is small and reviewable; the bundle is neither.

A team that hasn't deleted a flag in 6 months has 6 months of debt. Make removal as visible as creation.

## Evaluation performance & failure modes

- **In-process evaluation only.** A flag check should be a hashmap lookup, not a network call. Cache the rules in-process; background-refresh every 30–60s.
- **Defaults baked in code.** `flag.is_on("x", default=False)` — when the flag service is unreachable, the default fires. Pick defaults assuming the worst: "is this safe with the new code path?" → if no, default to false.
- **Initialization fail-safe.** First request after process start, before the first poll, the in-process cache is empty. Reads must return the baked default, not crash.
- **Streaming updates (SSE / WS) > polling** for low-latency flag changes. Most managed tools support streaming.

A flag library that can take the service down (because its eval blocks on a remote call that timed out) is upside-down — the flag *exists* to prevent outages, not cause them.

## Testing with flags

- **Test both paths.** Both `flag_on` and `flag_off` paths get tests. A bug in the off path during rollout flips production into the buggy branch.
- **Test the wrapper, not the flag library.** Inject a fake flag client; assert behavior per state.
- **Integration tests pin the flag** explicitly per scenario (not "whatever staging says today"). Tests that depend on the live flag service are flaky.

## Observability for flags

- **Counter per flag per outcome:** `flag_evaluations_total{flag_key, outcome}`.
- **Spans tagged with active flags** for the request — so traces explain why behavior differs.
- **Dashboard per flag during rollout:** error rate by variant, latency by variant, conversion by variant.
- **Audit log of flag changes:** who changed `flag_x` from 50% to 100%, when, what value before/after. For incident postmortems, this is gold.

## Anti-pattern fingerprints

- Flag with no type — defaults to debt. 🟡
- Flag with no expiration / owner — perpetual debt. 🟡
- Kill switch evaluation calls the very service the switch protects — fails when needed. 🔴 (correctness)
- Rollout jumping 5% → 100% — blast radius unbounded. 🔴 (scale)
- Flag check embedded directly in business logic across N files — cleanup will be a mass refactor. 🟡 (modularity)
- Flag default biased toward "on" / new path — when flag service fails, every user gets the new (untested-at-100%) path. 🔴 (resilience)
- Flag service is a single point of failure for request serving — outage cascades. 🔴 (resilience)
- Tests assert only `flag_on=true`; off-path untested — silent regression. 🟡
- Stale flags at 0% / 100% lingering > 90 days — code complexity tax forever. 🟡
- Flag changes have no audit log — postmortem reconstruction blind. 🟡

## Checklist

- [ ] Every flag has a type, owner, and expiration date (release/experiment) or quarterly review (ops/permission/kill).
- [ ] Kill switches for newly-launched features and high-blast-radius backend changes.
- [ ] Kill switch evaluation has no external dependency; defaults fail-safe.
- [ ] Gradual rollout follows the ladder; each rung observed before promotion.
- [ ] Automated kill on SLI breach for high-stakes flags.
- [ ] Flag check isolated to a thin seam; business logic unaware of the flag library.
- [ ] Both paths tested.
- [ ] Per-flag metrics + audit log + dashboard during rollout.
- [ ] Quarterly stale-flag audit; CI lints expired flag references.
