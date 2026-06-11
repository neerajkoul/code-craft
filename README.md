# code-craft

> An [Agent Skill](https://agentskills.io) that makes an AI coding assistant write and review **production-grade Python, Go, and TypeScript** the way a senior platform engineer would — test-first, resilient, secure, observable, and measured.

`code-craft` is a single `SKILL.md` plus a set of reference files that encode a
strong, opinionated engineering standard. Once loaded, it shapes **how** code is
written and reviewed: the assistant detects whether it's doing greenfield,
refactor, or review work; runs every change through a structured review
checklist; examines five mandatory dimensions (performance, modularity,
concurrency, memory, scale) on every task; and refuses to claim "done" without
running the verification command that proves it.

It is the standard I apply to my own work, written down so that an assistant
applies it consistently — and so the wrong conversations stop happening on a
team. The 2.1.0 release adds the per-language details that make this concrete:
boundary validation via Pydantic / `go-playground/validator` / Zod; env
configuration through `pydantic-settings` / `caarlos0/env` / Zod-on-`process.env`;
docstring + inline-comment conventions (PEP 257 / godoc / TSDoc); the
`try` / `except` / `finally` discipline (and its Go `defer` + TS `using`
parallels); and a memory-allocator deep-dive per language (CPython arenas,
Go escape analysis + `GOMEMLIMIT`, V8 hidden classes + heap sizing).

---

## Why this exists

LLM coding assistants are capable but have predictable failure modes: they make
silent assumptions on ambiguous requests, drive-by refactor unrelated code,
optimize without measuring, skip the error paths, and announce "tests pass"
without running them. `code-craft` is a counterweight. It turns those failure
modes into explicit, checkable rules:

- **Engage before coding.** State assumptions, surface ambiguity, push back when
  a simpler approach exists.
- **Surgical diffs.** In-path cleanup is required; off-path cleanup is mentioned,
  not made. Every changed line traces to the request.
- **Five mandatory dimensions, every time.** Performance, modularity,
  concurrency, memory, and scale get examined and *tagged* — even when the user
  didn't ask.
- **Resilience and security at design time**, not as a final pass.
- **No completion claim without evidence.** `IDENTIFY → RUN → READ → VERIFY →
  CLAIM`.

The reference files hold the depth — concrete patterns, profiler commands,
sizing math, idiomatic code per language — that the main file deliberately keeps
out of the always-loaded context.

---

## What's inside

```
code-craft/
├── SKILL.md                 # the standard: modes, principles, review checklist,
│                            #   five dimensions, review-comment style, verification gates
├── references/
│   ├── engagement.md        # how to engage before coding (adapted from Karpathy's notes)
│   ├── tdd.md               # the red-green-refactor loop, unit vs integration
│   ├── resilience.md        # pools, timeouts, circuit breakers, retries, degradation
│   ├── security.md          # threat modeling, OWASP-style checklist, dependency hygiene
│   ├── performance.md       # measurement loop, profilers, percentiles, system-level levers
│   ├── python.md            # idioms: layout, types, exceptions, pools, batching, tooling
│   ├── golang.md            # idioms: errors, interfaces-at-consumer, sync.Pool, errgroup
│   └── typescript.md        # idioms: strict types, undici, AbortSignal, vitest, + React
└── scripts/
    ├── lint.sh              # format + lint gate (Python: ruff/mypy, Go: gofmt/golangci-lint)
    └── test.sh              # test + coverage gate (pytest --cov-branch, go test -race)
```

| File | What it gives the assistant |
|------|------------------------------|
| `SKILL.md` | Mode detection, 10 core principles, the review checklist (anti-pattern fingerprints, scalability, reliability, perf, memory, security, subtle-bug deep pass), the WHAT/WHY/FIX review style, and the verification gates. Always loaded. |
| `engagement.md` | The "think before coding / surgical changes / goal-driven execution" discipline, with worked examples. |
| `tdd.md` | The test-first loop, test naming as spec, isolation, unit vs integration with testcontainers. |
| `resilience.md` | The four non-negotiables for any external call, with sizing math and tuning numbers. |
| `security.md` | Five-minute threat model, the paranoia checklist, `pip-audit`/`govulncheck` workflow. |
| `performance.md` | The five-step measurement loop, per-language profilers, percentile discipline, false economies, system-level levers. |
| `python.md` / `golang.md` / `typescript.md` | Idiomatic, well-commented reference code per language. Each ships parallel sections for **boundary validation** (Pydantic / `go-playground/validator` / Zod), **env-typed configuration** (`pydantic-settings` / `caarlos0/env` / Zod-on-`process.env`), **docstring + inline-comment format** (PEP 257 / godoc / TSDoc), **lint + format tooling** (Ruff / golangci-lint / ESLint + Prettier), **memory / allocator deep-dives** (CPython arenas + worker recycling; Go escape analysis + `GOMEMLIMIT`; V8 hidden classes + heap sizing), and the **`try` / `except` / `finally`** discipline (no `try/finally` alone; `defer` + named return + error wrap; `try / catch / finally` + `using` declarations). TypeScript also covers server-side Node plus a Browser/React section. |

---

## How it works

**Mandatory reference loading.** Before producing any code, diff, or review,
the skill instructs the assistant to read the cross-cutting references
(`engagement`, `tdd`, `resilience`, `security`, `performance`) plus the
language reference(s) in play. The main file and the references are treated as
**one prompt**.

**Mode detection.** The discipline differs by mode:

- **Greenfield** — failing test first, an interface in front of every external
  dependency, resilience primitives chosen upfront, threat model before any
  input/auth/secret handling.
- **Refactor** — minimal diff, in-path cleanup only, existing tests preserved.
- **Review** — one comment per issue in `WHAT / WHY / FIX` form with a severity
  tag and a dimension tag.

**The five mandatory dimensions.** Every task is examined across performance,
modularity, concurrency, memory, and scale — rendered as a pre-flight table
before the first function (writing) or a coverage table before the findings
(review). A genuinely N/A dimension is *stated*, not skipped.

**Verification gates.** Before any "tests pass" / "build green" / "bug fixed"
claim, the assistant must run the proving command and quote its output. Bundled
`scripts/lint.sh` and `scripts/test.sh` are the gate.

**Persistence.** Once triggered, the skill stays active for the whole
conversation — the review discipline re-applies on every code-touching turn
without re-invocation.

---

## Install

`code-craft` follows the [Agent Skills](https://agentskills.io) format
(`SKILL.md` with YAML frontmatter). The skill directory needs to be named
`code-craft`.

### Claude Code

Clone into your personal skills directory:

```bash
git clone https://github.com/<your-username>/code-craft.git ~/.claude/skills/code-craft
```

Or, to keep a skill scoped to one project, clone into the project's
`.claude/skills/` instead. Claude Code discovers the skill via its `SKILL.md`
frontmatter and loads it when a triggering condition matches.

### Any assistant that reads context files

The skill is plain Markdown. If your tool doesn't support the Agent Skills
format, point it at `SKILL.md` (and the `references/` it names) as project
context — for example via a rules/instructions file that includes them.

---

## Usage

The skill is written to **self-trigger**. Its frontmatter fires on:

- Creating or editing `*.py`, `*.go`, `*.ts`, `*.tsx`, `*.js`, `*.jsx`.
- Review intents: `/review`, "review this PR", "review the diff", "audit this".
- Build/fix intents: "implement X", "add a feature", "fix the bug", "refactor
  X", "make this faster/safer", "add tests", "harden this", "is this
  production-ready".
- Bash `gh pr diff/view/create`, `git diff`, `git show`.

You can also invoke it explicitly ("apply code-craft to this"). Off-switches:
ask it to "stop applying code-craft" / "skip the review", or work on something
with no code.

### The lint/test gate

The bundled scripts auto-detect the stack from the project root
(`pyproject.toml`/`setup.cfg` → Python, `go.mod` → Go) and can run both:

```bash
./scripts/lint.sh            # format + lint in place
./scripts/lint.sh --check    # CI mode: no edits, non-zero on any finding
./scripts/test.sh            # tests with branch coverage + race detector
./scripts/test.sh --coverage-floor 85
```

> Note: the bundled scripts cover Python and Go. TypeScript linting/testing is
> documented in `references/typescript.md` (`tsc --noEmit` + eslint + prettier,
> vitest with coverage) but is not wired into `scripts/` yet — see the roadmap.

---

## Token footprint

Because the references load on every code task, the skill is kept lean. The
current corpus is roughly **32k tokens** of Markdown — the 2.0.0 compression
pass removed internal redundancy without dropping rules, and the 2.1.0
additions (Pydantic / Zod / validator boundary schemas, env-typed settings,
docstring + lint conventions, deep memory-allocator coverage,
`try`/`except`/`finally` discipline) earn their bytes against new actionable
content rather than restating existing rules. See `CHANGELOG.md` for the
delta-by-delta history.

---

## Customize

It's all Markdown — fork it and make it yours.

- **Different defaults?** Edit the core principles in `SKILL.md` or the per-call
  numbers in `resilience.md`.
- **Another language?** Add `references/<lang>.md` in the same shape as the
  existing ones and list it under "read the language reference(s)" in `SKILL.md`.
- **Leaner context?** The biggest lever is the "read *all* references first"
  mandate — relax it to load only the references a task needs.

---

## Roadmap

- Wire TypeScript into `scripts/lint.sh` and `scripts/test.sh`.
- Optional "lean mode": load only the references a task needs instead of all of
  them.
- More language references (Rust, SQL).

---

## Attribution

`references/engagement.md` is adapted from
[multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT), which distills
[Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876)
on common LLM coding pitfalls. See [`NOTICE`](./NOTICE).

## License

[MIT](./LICENSE).

## Contributing

Issues and PRs welcome. The skill holds itself to its own standard, so a PR that
changes a rule should explain *why* (the mechanism, the failure it prevents) the
way a good review comment would. Keep reference code verbose and well-commented
— that style is intentional.
