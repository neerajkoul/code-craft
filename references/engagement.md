# Engagement principles

Open this when starting any non-trivial coding task. These govern *how* to
engage with the user and the task, before code is written — distinct from the
core principles in `SKILL.md` (which govern *what* the code looks like).

Adapted from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT), distilling [Karpathy's notes](https://x.com/karpathy/status/2015883857489522876)
on LLM coding pitfalls; examples and integration adapted.

These bias toward **caution over speed**. For trivial tasks (typo fixes,
one-liners), apply judgment — not every change needs full rigor. The goal is
fewer costly mistakes on non-trivial work, not slowing down simple tasks.

## 1. Think before coding

**Don't assume. Don't hide confusion. Surface tradeoffs.** The most common
LLM-session failure is silent assumption: the request was ambiguous, an
interpretation was picked, and the code ships before the user realizes it was
wrong. The fix is explicit reasoning before implementation.

**State assumptions explicitly.** Before writing, name the non-obvious
assumptions: what inputs are expected and where they come from; what the caller
owns vs what this code owns; what "done" means; what's out of scope. Uncertain
about one? Ask. A 30-second clarification beats 30 minutes building the wrong
thing.

> *"Add validation to the user signup endpoint."* →
> Assumptions: "validation" = input shape/format (well-formed email, password
> length), not business rules (email unique in DB); failure returns HTTP 400
> with a structured body, not an exception; existing handler structure stays.
> Say which is wrong and I'll adjust before writing.

**Present multiple interpretations when they exist.** Two-plus plausible
meanings → name them and ask. Don't pick silently.

> *"Make the cache TTL configurable."* →
> (1) per cache instance — one TTL set at construction (small change), or
> (2) per cache entry — caller passes TTL on each `set` (bigger, touches
> storage). Which?

**Push back when a simpler approach exists.** Asked for something complicated
with a materially simpler path to the same need → say so. This surfaces the
core principle "don't build for imaginary futures" when the user hasn't applied
it to this task.

> *"Build a plugin architecture to swap auth providers."* →
> How many providers today? If one, plus a "maybe SSO someday," a plugin
> architecture is a big cost for an imaginary future — one `AuthProvider`
> interface with a single impl and a config switch when the second arrives is
> cheaper. If the second is already coming, plugin is right. Which is it?

**Stop when confused.** Genuinely unclear request, code, or intent → name
what's unclear and ask. A best-guess at a confused understanding produces
subtly-wrong code.

> *"Fix the bug in the worker."* → Which worker, which bug? I see three worker
> classes and no failing test. Point me to the failure (log, stack, repro) or
> the file.

## 2. Surgical changes

**Touch only what you must. Clean up only what your change orphaned.** Refines
"leave the code better than you found it" — same idea, scoped.

- **In-path cleanup is required.** Poorly named var, magic number, undocumented
  edge case *in the function you're modifying* → fix it; it's related to the
  task.
- **Off-path cleanup is not.** Don't reformat an adjacent function, "improve" a
  neighbor's docstring, or rename a class to your taste. Unrelated → *mention*
  it in the response, don't change it.
- **Match existing style** even if you'd do it differently — raise preferences
  separately, don't apply them silently.
- **Clean your own orphans.** Remove imports/vars/helpers *your* change made
  unused. Don't delete pre-existing dead code — mention it.

The test: **every line in your diff traces to the request or to cleanup the
request genuinely requires.** A 200-line diff where 150 are drive-by
improvements is far harder to review, blame, and bisect than the 50 that matter.

## 3. Goal-driven execution

**Define success criteria. State the plan. Loop until verified.** Extends the
TDD discipline in `tdd.md` from "write the test that defines done" to "state
how each step is verified, then loop until all checks pass."

Transform imperative tasks into verifiable goals:

| User says | Transform to |
|---|---|
| "Add validation" | Write tests for invalid inputs that fail today, make them pass |
| "Fix the bug" | Write a test reproducing the bug, make it pass |
| "Refactor X" | Confirm tests pass, refactor, confirm they still pass |
| "Make it faster" | Benchmark, capture baseline, change, verify the number improved |
| "Add a feature" | Unit test for new behavior → integration test → implementation |

Each transformed goal has a binary check. Imperative tasks ("make it work")
have none and lead to after-the-fact clarification.

**State the plan for multi-step tasks** with a verification per step, up front,
before any code:

```
1. Add `UserSignupRequest` pydantic model (email/password)
   → verify: rejects bad email, accepts good (unit test)
2. Wire validation into the signup handler
   → verify: 400 on bad input, 200 on good (integration test)
3. Add field-level error response shape
   → verify: assert on response JSON structure (integration test)
```

The user can correct course before implementation — much cheaper than after.

**Loop until verified.** Work the steps; after each, run the check, move on if
green, fix and re-check if red. The user shouldn't have to ask "is it done?"

**Strong vs weak criteria.** Strong (concrete, runnable, binary) lets the loop
run independently. Weak ("make it work", "clean it up") has no terminal
condition — propose a strong one and confirm first:

> "Make it faster" → I'll add a benchmark for `process_batch`, capture the
> baseline (~X ms), aim for ≥2× verified by re-running it. OK?

## Checklist before starting

For any non-trivial task:

- [ ] Stated my non-obvious assumptions?
- [ ] Request unambiguous, or do I present interpretations?
- [ ] Simpler approach to suggest?
- [ ] Anything unclear to ask about first?
- [ ] What's the verifiable "done" criterion?
- [ ] Multi-step → what's the plan and the per-step check?
- [ ] Will every diff line trace to the request (not drive-by refactoring)?

A "no" to any is a signal to pause before writing.
