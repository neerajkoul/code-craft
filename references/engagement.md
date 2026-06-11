# Engagement principles

Open for any non-trivial coding task. These govern *how* to engage with the user and the task; `SKILL.md` governs *what* the code looks like. Adapted from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) (MIT), distilling [Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

**Tradeoff:** these bias toward caution over speed. For trivial tasks (typo fixes, one-liners), apply judgment — the goal is reducing costly mistakes on non-trivial work, not slowing simple tasks.

## 1. Think before coding

**Don't assume. Don't hide confusion. Surface tradeoffs.** The most common failure mode is silent assumption: an ambiguous request, a silently picked interpretation, code shipped before the user realizes it was the wrong one.

### State assumptions explicitly

Before writing code, name the non-obvious assumptions: what inputs the code expects and from where; caller's responsibility vs this code's; what "done" means; what's out of scope. If any assumption is uncertain, ask — a 30-second clarification beats 30 minutes of building the wrong thing.

Example shape — "Add validation to the signup endpoint":
> Assumptions: "validation" = input shape/format checks (email well-formed, password length), not business rules (email unique in DB); failures return HTTP 400 with a structured body; existing handler structure stays. If any is wrong, say which.

### Present multiple interpretations when they exist

Two or more plausible meanings → name them, ask which. Don't pick silently. Example — "Make the cache TTL configurable": per-instance (small change) vs per-entry (touches the storage layer). Which?

### Push back when a simpler approach exists

If a materially simpler way meets the same need, say so — it's a peer-engineer service, not disobedience. Example — "Build a plugin architecture to swap auth providers": with one provider today and a hypothetical second, a single `AuthProvider` interface + one implementation is much cheaper; plugin architecture is right only if the second provider is real. This is the "no abstractions for imaginary futures" principle surfaced at task time.

### Stop when confused

Genuinely unclear request / code / intent → name what's unclear and ask. A best-guess on a confused understanding produces subtly wrong code. Example — "Fix the bug in the worker": which worker, which bug? Point to the failure (log, stack trace, repro) or the file.

## 2. Surgical changes

**Touch only what you must. Clean up only what your change makes orphaned.**

### In-path vs off-path

- **In-path cleanup is required.** Poorly named variable, magic number, undocumented edge case on a line you're modifying → fix as part of the change.
- **Off-path cleanup is not.** Don't reformat adjacent functions, "improve" neighbors' docstrings, or rename for style preference.

Test: **every line in the diff traces to the request, or to cleanup genuinely required by it.**

### When editing existing code

- Don't "improve" adjacent code, comments, or formatting you don't have to touch.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently — raise style preferences separately.
- Notice unrelated dead code or a smell → *mention it*, don't delete it. Surfacing without acting respects the user's right to scope the change.

### Orphans

- Remove imports, variables, and helpers that *your* change made unused.
- Don't remove pre-existing dead code. Mention it.

### Why

Diffs are how reviewers verify correctness. 50 real lines + 150 drive-by lines is far harder to review, blame, and bisect than 50 lines.

## 3. Goal-driven execution

**Define success criteria. State the plan. Loop until verified.** Extends the TDD discipline (`references/tdd.md`) to: write the test, state how each step is verified, loop until all verifications pass.

### Transform imperative tasks into verifiable goals

| User says | Transform to |
|---|---|
| "Add validation" | Tests for invalid inputs that fail today → make them pass |
| "Fix the bug" | Test reproducing the bug → make it pass |
| "Refactor X" | Existing tests pass before → refactor → still pass after |
| "Make it faster" | Benchmark, capture baseline, change, verify improvement |
| "Add a feature" | Unit test for the behavior → integration test → implementation |

Each transformed goal has a binary check. Imperative tasks ("make it work") have none and lead to after-the-fact clarification.

### State the plan for multi-step tasks

Anything > 1–2 steps gets a plan up front, with a verification per step:

```
1. Add `UserSignupRequest` pydantic model
   → verify: rejects bad email, accepts good (unit test)
2. Wire validation into the signup handler
   → verify: 400 on bad input, 200 on good (integration test)
3. Add error response shape with field-level details
   → verify: assertion on response JSON structure
```

The user can correct course before any code is written — much cheaper than after.

### Loop until verified

After each step: run the check; pass → next; fail → fix and re-check. The user shouldn't have to ask "is it done?"

### Strong vs weak criteria

Strong criteria (concrete, runnable, binary) let the loop run independently. Weak criteria ("make it work", "clean it up") have no terminal condition — propose a strong one and confirm first:

> "Make it faster" → "I'll benchmark `process_batch`, capture baseline, aim for ≥2× verified by re-run. OK?"

## How these relate to the rest of the skill

Engagement principles fire **first** — before code. Core principles (`SKILL.md`) govern the code once writing starts; language refs give idioms; TDD ref governs the test-first loop; resilience and security refs govern dependency and trust-boundary concerns. Without engagement, the rest of the skill applies to the wrong problem.

## Checklist before starting

- [ ] Stated my non-obvious assumptions?
- [ ] Request unambiguous, or do I present interpretations?
- [ ] Simpler approach I should suggest?
- [ ] Anything unclear to ask about before coding?
- [ ] Verifiable success criterion for "done"?
- [ ] Multi-step: plan with a check per step?
- [ ] Every diff line traces to the request — no drive-by refactoring?

Any "no" → pause before writing.
