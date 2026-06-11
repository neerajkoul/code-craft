# Changelog

All notable changes to `code-craft` are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/), and the project
follows semantic-ish versioning for a prompt artifact (major = behavior change,
minor = added content, patch = fixes/wording).

## [2.0.0] — 2026-06-11

### Changed

- **Token-footprint pass across the whole corpus (~37k → ~30k tokens, ≈20%).**
  Because every reference loads on every code task, the instructions were
  compressed to reduce always-on context cost.
  - `SKILL.md` (~14.2k → ~11.0k, ≈22%): deduplicated the five-mandatory-dimension
    scaffolding that was restated across four sections, merged overlapping
    anti-pattern catalogs, folded redundant sub-headers into prose. **Every
    unique rule, pattern, table, and trigger phrase preserved.**
  - References (~23k → ~18.5k, ≈19%): tightened prose, removed meta
    "how this relates to the rest of the skill" sections, collapsed
    multi-sentence explanations. In the language references
    (`python`/`golang`/`typescript`) **all code blocks are preserved verbatim** —
    only connective prose changed.

### Notes

- No rules were dropped. This is a compression of wording, not of scope.

## [1.0.0] — 2026-05-28

### Added

- `SKILL.md`: the core standard — mode detection (greenfield / refactor /
  review), ten core principles, the five mandatory engineering dimensions with
  an enforcement scan and severity floor, the review checklist (anti-pattern
  fingerprints, scalability, reliability, performance, memory, security,
  production readiness, a subtle-bug deep pass, and a CPU/memory budget pass),
  diff-shape heuristics, the WHAT/WHY/FIX review-comment style, the
  receiving-feedback pattern, and the verification gates.
- `references/engagement.md`: think-before-coding, surgical changes, goal-driven
  execution (adapted from Karpathy's LLM-coding notes).
- `references/tdd.md`: the red-green-refactor loop, test naming, isolation, unit
  vs integration with testcontainers, coverage discipline.
- `references/resilience.md`: the four non-negotiables for external calls, pool
  sizing math, timeout/breaker/retry tuning, lazy-startup rationale, graceful
  degradation.
- `references/security.md`: design-time threat modeling, an OWASP-style
  checklist, dependency hygiene with `pip-audit`/`govulncheck`.
- `references/performance.md`: the measurement loop, per-language profilers,
  percentile discipline, Amdahl triage, latency-vs-throughput, false economies,
  system-level levers, a benchmarking checklist.
- `references/python.md`, `references/golang.md`, `references/typescript.md`:
  idiomatic, well-commented reference code per language (TypeScript includes a
  Browser/React section).
- `scripts/lint.sh`, `scripts/test.sh`: the format/lint and test/coverage gates
  for Python and Go.

[2.0.0]: https://github.com/<your-username>/code-craft/releases/tag/v2.0.0
[1.0.0]: https://github.com/<your-username>/code-craft/releases/tag/v1.0.0
