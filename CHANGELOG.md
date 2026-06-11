# Changelog

All notable changes to `code-craft` are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/), and the project
follows semantic-ish versioning for a prompt artifact (major = behavior change,
minor = added content, patch = fixes/wording).

## [2.1.0] — 2026-06-11

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

[2.1.0]: https://github.com/<your-username>/code-craft/releases/tag/v2.1.0
[2.0.0]: https://github.com/<your-username>/code-craft/releases/tag/v2.0.0
[1.0.0]: https://github.com/<your-username>/code-craft/releases/tag/v1.0.0
