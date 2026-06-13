# Changelog

All notable changes to `code-craft` are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/), and the project
follows semantic-ish versioning for a prompt artifact (major = behavior change,
minor = added content, patch = fixes/wording).

## [2.2.0] — 2026-06-13

### Added

- **`scripts/review-scan.sh`** — mechanical anti-pattern grep across changed
  files. 49 patterns across Python / TypeScript / Go (18 / 16 / 15 categories).
  Runs as `scripts/review-scan.sh [base] [head]` / `--staged` / `--paths` /
  `--list-patterns`. Output format `LANG | TAG | file:line: matched_text`.
  Exit 0 iff zero hits; CI-gate-friendly.
  - Operationalises the *Fast pass > Mechanical scan* section of SKILL.md so
    reviews don't rely on "I'll spot those naturally" (which catches nothing).
  - Unified justification matcher
    `_HAS_REASON='([A-Z]{1,5}[0-9]{2,4}|[a-z]{4,})'` — accepts a lint rule code
    (E501, F401, ARG002, TS2304, S101) or a ≥4-letter word. Reused by
    `noqa-no-reason` / `nolint-no-reason` / `eslint-disable-no-reason`.
  - Python pass: silenced failures, bare suppression comments, inline imports,
    mutable defaults, `== None|True|False`, `range(len)`, insecure RNG,
    missing `timeout=` on `requests`/`httpx`, f-string into SQL/shell,
    `**kwargs` passthrough, `os.environ.get` outside config, `assert` / `print`
    / `time.sleep` in non-test code, bare TODOs.
  - TypeScript / JS pass: `: any` / `as any`, `as <T>` (excluding `as const` /
    `as unknown`), non-null `!`, loose `==` / `!=`, `Math.random`, bare
    `eslint-disable` / `@ts-ignore` / `@ts-nocheck`, `console.log` non-test,
    `fetch(` without `signal:`, bare `JSON.parse`, empty `.catch(() => {})`,
    `eval(` / `new Function(`, `setTimeout(string, …)` eval form, banned
    `Function` / `Object` type, axios import, `process.env.X` outside config,
    bare TODOs.
  - Go pass: ignored error returns, `http.DefaultClient`, `math/rand` for
    security, `fmt.Sprintf` into SQL, `fmt.Errorf` without `%w`, bare
    `// nolint`, `panic(` non-test, `regexp.MustCompile` inside a function,
    `ioutil.*` (deprecated), `time.Sleep` non-test, `interface{}` use, bare
    `recover()` without re-panic, bare TODOs. Two patterns documented as
    manual-only (`defer-in-loop`, `go-func-fire-forget`) — too noisy for a
    one-line regex without AST awareness.
- **`SKILL.md` > Review checklist > Fast pass > Mechanical scan** — new
  subsection placing the grep pass *before* the prose pass. Procedure
  (run / triage / inline / log), self-check, false-positive discipline.
  Regexes live in the script, not in the skill text — SKILL.md describes
  WHAT each language pass catches in prose; `scripts/review-scan.sh
  --list-patterns` is the source of truth for the patterns themselves.
- **`SKILL.md` > Review checklist > Fast pass > Anti-pattern fingerprints
  extended** — added two entries:
  - **Inline import inside a function body** with no cycle / optional-dep /
    cost justification — explicit rule, since this was the recurring miss
    that motivated the mechanical-scan rework.
  - **Stacked / cross-PR conflicts and description-vs-diff drift** under
    *Diff-shape heuristics* — PR description says X, diff does Y; cross-PR
    symbol imports that another open PR deletes.
- **`SKILL.md` > Review checklist > Cross-service contracts** (new
  subsection) — BFF↔backend identity forwarding, audit attribution from
  verified identity (not payload), string-typed cross-service coupling
  (activity / signal / queue / event names) as a shared-module discipline,
  "out of scope" follow-ups that leave the system broken mid-rollout.
- **`SKILL.md` > Review checklist > Distributed-system patterns** (new
  subsection) — at-least-once + dedup, workflow caps (turns / history /
  age), replay-determinism, external-first writes needing compensating
  undo / reconciler / two-phase, retry storms.
- **`SKILL.md` > Review checklist > Observability** (new subsection) —
  three-signals split, cardinality budgets, correlation ids across logs /
  metrics / traces, replay-safety, sampler discipline.
- **`SKILL.md` > Pre-post checklist** (new subsection under *Review-mode
  output style*) — 8 mandatory boxes before submit:
  mechanical scan ran / scan summary in verdict / 5-dim table at top /
  anti-relabel check / backwards-compat scan / PR-description vs diff /
  no drive-by nits / severity floor honored.
- **`references/observability.md`** (new, ~220 lines) — logs / metrics /
  traces discipline, level rubric, cardinality budgets, sampler design,
  replay-safety, correlation ids. Opens conditionally when a diff emits
  logs / metrics / traces or sizes a sampler.
- **`references/migrations.md`** (new, ~190 lines) — expand-contract, the
  `DROP TABLE IF EXISTS` landmine, partial-unique-for-soft-delete,
  `CONCURRENTLY` index creation, online data migrations,
  downgrade discipline. Opens when authoring or reviewing DDL.
- **`references/api-contracts.md`** (new, ~200 lines) — BFF↔backend
  identity forwarding (signed headers vs body claims), audit attribution,
  string-typed cross-service coupling, schema evolution per layer, contract
  tests. Opens when touching any cross-process boundary.
- **`references/distributed.md`** (new, ~280 lines) — at-least-once +
  idempotency keys, entity workflow per natural-id, continue-as-new caps,
  synchronous signal handlers, replay-determinism, sagas + compensating
  actions, retry storms, distributed locks + fencing tokens, clocks.
  Opens for workflow engines / brokers / sagas / distributed locks.
- **`references/python.md` > Imports — module top, not inline** (new
  section) — three legitimate cases for deferred imports (cycle / optional
  dep / expensive); counter-examples (stdlib re-imports, redundant
  shadowing of a top-level import); `F811` cross-reference.

### Changed

- **`SKILL.md` > Review posture** now leads with "mechanical pass first,
  prose pass second" so the cheapest part of review runs before review
  fatigue sets in.
- **`SKILL.md` > Mandatory reference loading** split into required (5) +
  conditional (4); the four new references open only when the diff
  touches that surface.
- **`SKILL.md` > Review checklist > Backwards compatibility** points at
  the new `references/api-contracts.md` and `references/migrations.md`.
- **`SKILL.md` > Review checklist > Subtle bugs > Concurrency** points at
  the partial-unique-for-soft-delete + `INSERT … ON CONFLICT` pattern in
  `references/migrations.md`.
- **`SKILL.md` > Review checklist > Security > Authn vs authz** points at
  the BFF↔backend identity-forwarding discipline in
  `references/api-contracts.md` (the recurring IDOR shape: backend trusts
  body-supplied `user_id`).
- **README.md** synced to list the new references + `scripts/review-scan.sh`,
  with conditional-load explanation.

### Notes

- **Motivating miss.** A PR review missed eight inline imports in
  `artifact_store/` (PR #357). The skill rule existed but only as prose; no
  mechanical enforcement. This release turns the rule into a runnable
  scanner and codifies "mechanical pass before prose pass" as posture.
- **Regexes live in one place.** `SKILL.md` describes categories in prose;
  `scripts/review-scan.sh` owns the patterns. Refining a pattern means
  editing one file, not two. `--list-patterns` is the self-documentation.
- **False-positive discipline.** Patterns producing > 30% FP get refined
  or dropped. Intentional hits get a justified suppression comment so the
  next scan doesn't re-flag them. Review fatigue from grep noise erases
  the benefit.

## [2.1.0] — 2026-06-12

### Added

- **`Validation at boundaries`** section in each language reference — schema-
  driven parsing at every untrusted edge (HTTP body, queue message, webhook
  payload, LLM tool args, config file).
  - `python.md`: Pydantic v2 — `BaseModel`, `Field` constraints, narrow types
    (`EmailStr` / `HttpUrl` / `SecretStr`), `field_validator` /
    `model_validator`, `ConfigDict(extra="forbid")`, hot-path `TypeAdapter`
    reuse, FastAPI integration rule.
  - `golang.md`: `go-playground/validator` — struct tags, custom validators,
    struct-level cross-field rules, single shared validator instance,
    `protovalidate-go` mention for gRPC.
  - `typescript.md`: Zod — `safeParse`, `.strict()`, narrow types
    (`z.string().email()` / `.url()` / `.uuid()`), `discriminatedUnion`,
    `.refine()`, module-scope caching, valibot/arktype alternatives.
- **`Configuration — env vars`** section, replacing the prior dataclass /
  bare-struct examples with the typed-settings pattern.
  - `python.md`: `pydantic-settings.BaseSettings` — `env_prefix`,
    `extra="forbid"`, `SecretStr`, `frozen=True`, `Field` bounds,
    `@lru_cache` accessor.
  - `golang.md`: `caarlos0/env` — `required` / `unset` tags, post-parse
    validation, `sync.Once` accessor, viper mention for multi-source.
  - `typescript.md`: Zod-on-`process.env` — service-prefixed vars,
    `z.coerce.number`, `Object.freeze` caching, `envalid` and
    `@t3-oss/env-core` alternatives.
- **`Comment & docstring format`** section in each language reference.
  - `python.md`: PEP 257 + Google-style docstrings, inline why-comments,
    `# noqa: RULE — reason` format, `# TODO(@author, YYYY-MM-DD)` convention.
  - `golang.md`: godoc rules (symbol-name-first sentence, `[Link]`,
    `Deprecated:`), `// nolint:rule // reason` enforced by `nolintlint`.
  - `typescript.md`: TSDoc (`@param` / `@returns` / `@throws` / `{@link}`),
    `// eslint-disable-next-line rule -- reason`, `@ts-expect-error`
    preferred over `@ts-ignore`.
- **`Tooling`** section expanded with concrete lint/format/typecheck config.
  - `python.md`: Ruff config (`E`/`W`/`F`/`I` = PEP 8 + pyflakes + isort,
    plus `B`/`C4`/`UP`/`SIM`/`RUF`/`ASYNC`/`S`/`N`/`PT`/`RET`/`TID`), PEP 8
    essentials, mypy `--strict`, bandit-via-Ruff.
  - `golang.md`: `golangci-lint` `.golangci.yml` config (errcheck, govet,
    staticcheck, unused, gocritic, gosec, revive, nolintlint, ineffassign,
    misspell, gocyclo, bodyclose, sqlclosecheck, contextcheck, errorlint),
    `gofmt` + `govulncheck`.
  - `typescript.md`: `tsconfig.json` strict flags
    (`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`,
    `useUnknownInCatchVariables`), ESLint `recommended-type-checked` +
    `no-floating-promises` / `no-misused-promises` /
    `consistent-type-imports` / `switch-exhaustiveness-check`, Prettier
    integration via `eslint-config-prettier`.
- **`Memory`** section deepened with arena / GC / monomorphism details.
  - `python.md`: new **`Memory, arenas, and fragmentation`** section —
    CPython `pymalloc` arenas explained, non-compaction consequences,
    `__slots__`, `gc.freeze()` post-startup, `gc.set_threshold` tuning,
    `PYTHONMALLOC=malloc` for jemalloc/mimalloc, `weakref.finalize` over
    `__del__`, worker recycling as the durable fix, bounded streaming
    pipeline pattern.
  - `golang.md`: **`Escape analysis, GC pressure, and GOMEMLIMIT`**
    subsection — `go build -gcflags="-m"`, heap-profile audit, slice
    retention bug (slicing 100 MB to read 10 bytes), reflection-in-json
    cost, `GOMEMLIMIT` for soft-ceiling-before-OOM-kill.
  - `typescript.md`: **`V8 hidden classes and monomorphism`** — initialise
    all fields in constructor in fixed order, no `delete`, no heterogeneous
    arrays, no prototype mutation. Plus **`Heap sizing and GC tuning`** —
    `--max-old-space-size`, `--max-semi-space-size`, Chrome DevTools heap
    snapshots, `clinic heapprofiler`. Plus **`Closure-retention bugs`** —
    extract primitives before long-lived callbacks.
- **`try` / `except` / `finally`** discipline as an explicit subsection.
  - `python.md`: `try + finally` alone is a smell; observe before
    propagating; `from exc` chains; context managers > manual pattern;
    `asyncio.CancelledError` re-raise rule.
  - `golang.md`: parallel — `defer + named return + error wrapping`. Bare
    `defer fn()` whose `fn` returns an error drops the failure; LIFO
    ordering on multiple defers; no `defer` inside a loop.
  - `typescript.md`: parallel — `try / catch / finally` (not
    `try / finally`), `catch (err: unknown)` + `instanceof` narrowing,
    `AbortSignal` cleanup in `finally`, `using` declarations (TS 5.2+) as
    the `Disposable` replacement.
- **`SKILL.md` anti-pattern fingerprints** extended with two new entries
  spanning all three languages:
  - `try` + `finally` with no `except` (Py) / no `catch` (TS) / bare
    `defer fn()` whose `fn` returns an error (Go).
  - Pydantic-less request handler (Py), `validator`-less JSON binding (Go),
    `zod`-less `JSON.parse` of untrusted payload (TS).

### Changed

- `python.md` *Constants and configuration* split into two sections:
  *Constants* (literals + `@dataclass(frozen=True, slots=True)` for value
  objects) and *Configuration — `pydantic-settings`* (env-driven config).
  Old `dataclass`+`from_env()` example removed.
- `python.md` *Memory and allocation* demoted to a quick-reference checklist
  since the depth now lives in *Memory, arenas, and fragmentation*.

### Notes

- All additions earn their bytes against new rules and patterns, not
  duplication. The compression discipline from 2.0.0 still applies — every
  new sentence introduces something actionable.
- Corpus footprint: ~30k → ~32k tokens (≈+7%) covering the new per-language
  sections. Net growth lives in the language references (`python.md`,
  `golang.md`, `typescript.md`); `SKILL.md` grew by two anti-pattern
  fingerprint lines only.
- `README.md` synced to reflect the new section coverage and footprint.

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

[2.2.0]: https://github.com/<your-username>/code-craft/releases/tag/v2.2.0
[2.1.0]: https://github.com/<your-username>/code-craft/releases/tag/v2.1.0
[2.0.0]: https://github.com/<your-username>/code-craft/releases/tag/v2.0.0
[1.0.0]: https://github.com/<your-username>/code-craft/releases/tag/v1.0.0
