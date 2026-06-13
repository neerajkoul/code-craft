#!/usr/bin/env bash
# review-scan.sh — mechanical anti-pattern grep across changed files.
#
# Usage:
#   scripts/review-scan.sh                   # diff vs origin/main
#   scripts/review-scan.sh main              # diff vs <branch>
#   scripts/review-scan.sh main HEAD~5       # diff between two refs
#   scripts/review-scan.sh --staged          # scan staged changes
#   scripts/review-scan.sh --paths 'foo/**'  # scan specific paths
#   scripts/review-scan.sh --list-patterns   # print every pattern + description
#
# The script runs every applicable language pass on the changed files and
# prints each hit as `LANG | PATTERN | file:line: matched_text`.
# Exit status: 0 if zero hits, 1 if any hit (so CI can gate; review is the
# author triaging the list, not making it green).
#
# This is the operationalised version of code-craft SKILL.md > Review
# checklist > Fast pass > Mechanical scan. Read that section first to
# understand which hits are real findings vs intentional + justified.

set -uo pipefail

# ---------------------------------------------------------------------------
# CLI parse
# ---------------------------------------------------------------------------

STAGED=0
LIST_PATTERNS=0
BASE_REF="origin/main"
HEAD_REF="HEAD"
EXPLICIT_PATHS=""
BASE_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --staged)
      STAGED=1
      shift
      ;;
    --paths)
      EXPLICIT_PATHS="$2"
      shift 2
      ;;
    --list-patterns)
      LIST_PATTERNS=1
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      if [ -z "$BASE_OVERRIDE" ]; then
        BASE_REF="$1"
        BASE_OVERRIDE=1
      else
        HEAD_REF="$1"
      fi
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Pattern table (tag, description) — used by --list-patterns and the scans
# below. Keep this synchronised with the scan() calls.
# ---------------------------------------------------------------------------

print_pattern_table() {
  cat <<'TABLE'
LANG  TAG                              WHAT IT CATCHES
----  ------------------------------   --------------------------------------------------
py    except-pass                      `except: pass` / `except Exception: pass` — silenced failure.
py    except-baseexception             `except BaseException` — catches KeyboardInterrupt / SystemExit.
py    noqa-no-reason                   `# noqa` / `# type: ignore` with no rule code or word-reason.
py    inline-import                    `import` / `from … import` inside a function body. Cycle / optional-dep / cost only.
py    mutable-default-arg              `def f(x=[])` / `def f(x={})` — mutable default shared across calls.
py    ==None/True/False                `== None|True|False` — use `is`.
py    range(len(...))                  Use `enumerate(seq)`.
py    insecure-rng                     `random.random` / `random.choice` / `random.randint` for tokens / ids.
py    requests-no-timeout              `requests.get/post/...` without `timeout=`.
py    httpx-no-timeout                 `httpx.get/post/AsyncClient()` without `timeout=`.
py    f-string-into-sql                `execute(f"SELECT …")` — SQL injection.
py    f-string-into-shell              `subprocess.run([f"…"])` — shell injection.
py    todo-no-issue                    New `# TODO` without an issue ref (#123 / GH-123 / ENG-123).
py    **kwargs-passthrough             `def f(**kwargs)` with no further unpacking — type erasure layer.
py    assert-non-test                  `assert` in non-test code — disabled under `-O`.
py    print-non-test                   `print()` outside CLI / scripts — should be structured logger.
py    time.sleep-non-test              `time.sleep` / `asyncio.sleep` in non-test code — usually a missing signal.
py    os.environ.get                   `os.environ.get` outside config — config drift / perf smell.

ts    explicit-any                     `: any` / `as any` — type-system bypass.
ts    as-cast                          `as <T>` (excluding `as const` / `as unknown`).
ts    non-null-assertion               `x!.field` — usually hiding a narrowing the compiler can't see.
ts    loose-equality                   `==` / `!=` — use `===` / `!==`.
ts    Math.random                      Insecure RNG for tokens / ids — use `crypto.randomBytes`.
ts    console.log-non-test             `console.log/debug/info` in library code.
ts    eslint-disable-no-reason         `eslint-disable` / `@ts-ignore` / `@ts-nocheck` with no rule code or word-reason.
ts    fetch-no-signal                  `fetch(` without an `AbortSignal` — unbounded request.
ts    JSON.parse-bare                  `JSON.parse(` without a schema validator (zod, valibot, …) around it.
ts    empty-catch                      `.catch(() => {})` or `.catch(() => null)` — silenced promise rejection.
ts    eval-or-Function                 `eval(` / `new Function(` — runtime code construction.
ts    setTimeout-string                `setTimeout("…")` — eval form.
ts    banned-type                      `Function` / `Object` parameter or property type — too wide.
ts    axios-import                     `import … from "axios"` — has no default timeout; prefer `undici`/`fetch` + signal.
ts    process.env-non-config           `process.env.X` outside `config/` — config drift.
ts    todo-no-issue                    New `// TODO` without an issue ref.

go    ignored-err                      `_ = fn(...)` on a returned error.
go    http.DefaultClient               No timeout. Use a configured client.
go    math/rand-import                 `math/rand` for security tokens — use `crypto/rand`.
go    fmt.Sprintf-into-sql             `fmt.Sprintf("SELECT …")` — SQL injection.
go    fmt.Errorf-no-wrap               `fmt.Errorf("...: " + err.Error())` style or no `%w` verb — error wrapping lost.
go    nolint-no-reason                 `// nolint` with no rule code or word-reason.
go    panic-non-test                   `panic(` in non-test code — input validation should return error.
go    regexp-MustCompile-in-func       `regexp.MustCompile` inside a function — recompiles per call.
go    ioutil-deprecated                `ioutil.*` — replaced by `io` / `os` in Go 1.16+.
go    time.Sleep-non-test              `time.Sleep` in non-test code — usually a missing signal.
go    empty-interface                  `interface{}` parameter / field — use `any` (Go 1.18+) or a real interface.
go    recover-bare                     `recover()` without re-panic / logged-and-rethrown.
go    todo-no-issue                    New `// TODO` without an issue ref.

(Manual-only Go checks — too noisy for a one-line regex; flag during the prose pass.)
go    defer-in-loop                    `defer` inside a `for` loop — fd / handle pileup. Use `go vet -vettool=loopvar` or wrap loop body in a closure.
go    go-func-fire-forget              `go func() { … }()` without a stop signal (`ctx` / `errgroup`) — goroutine leak.
TABLE
}

if [ "$LIST_PATTERNS" -eq 1 ]; then
  print_pattern_table
  exit 0
fi

# ---------------------------------------------------------------------------
# Collect changed files
# ---------------------------------------------------------------------------

if [ -n "$EXPLICIT_PATHS" ]; then
  # Word-splitting on $EXPLICIT_PATHS is intentional for glob expansion.
  # shellcheck disable=SC2086
  CHANGED=$(git ls-files $EXPLICIT_PATHS 2>/dev/null)
elif [ "$STAGED" -eq 1 ]; then
  CHANGED=$(git diff --cached --name-only --diff-filter=AM 2>/dev/null)
else
  CHANGED=$(git diff --name-only --diff-filter=AM "$BASE_REF...$HEAD_REF" 2>/dev/null)
fi

if [ -z "$CHANGED" ]; then
  echo "review-scan: no changed files" >&2
  exit 0
fi

PY_FILES=$(echo "$CHANGED" | grep -E '\.py$' || true)
TS_FILES=$(echo "$CHANGED" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$' || true)
GO_FILES=$(echo "$CHANGED" | grep -E '\.go$' || true)

PY_NON_TEST=$(echo "$PY_FILES" | grep -v '_test\.py$' || true)
PY_NON_INFRA=$(echo "$PY_NON_TEST" | grep -v -E '(^cli/|/cli/|scripts/|/config(_[a-z]+)?\.py$)' || true)
TS_NON_TEST=$(echo "$TS_FILES" | grep -v -E '(_test\.|\.test\.|\.spec\.|/test/|/__tests__/)' || true)
TS_NON_CONFIG=$(echo "$TS_NON_TEST" | grep -v -E '(^config/|/config/|\.config\.|env\.ts$)' || true)
GO_NON_TEST=$(echo "$GO_FILES" | grep -v '_test\.go$' || true)

HITS_TOTAL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# scan LANG TAG FILES PATTERN [INVERT_PATTERN]
#  - LANG / TAG: labels for the output line
#  - FILES: newline-separated file list (may be empty — function no-ops)
#  - PATTERN: ERE passed to grep -nE
#  - INVERT_PATTERN (optional): rows matching this are filtered out
#    (justifications, e.g. `noqa.*[A-Za-z]{6,}` for a noqa with a real reason).
scan() {
  local lang="$1"
  local tag="$2"
  local files="$3"
  local pattern="$4"
  local invert="${5:-}"

  if [ -z "$files" ]; then
    return
  fi

  local hits
  # Word splitting on $files is intentional (multi-file grep).
  # shellcheck disable=SC2086
  if [ -n "$invert" ]; then
    hits=$(grep -nE "$pattern" $files 2>/dev/null | grep -v -E "$invert" || true)
  else
    hits=$(grep -nE "$pattern" $files 2>/dev/null || true)
  fi

  if [ -n "$hits" ]; then
    while IFS= read -r line; do
      echo "$lang | $tag | $line"
      HITS_TOTAL=$((HITS_TOTAL + 1))
    done <<< "$hits"
  fi
}

# Justification matcher — common to noqa / nolint / eslint-disable.
# Accepts: a lint rule code (e.g. E501, F401, ARG002, TS2304, S101) OR a
# ≥4-letter lowercase word (e.g. "cycle", "shadow", "broken").
_HAS_REASON='([A-Z]{1,5}[0-9]{2,4}|[a-z]{4,})'

# ---------------------------------------------------------------------------
# Python pass
# ---------------------------------------------------------------------------

if [ -n "$PY_FILES" ]; then
  scan py "except-pass"            "$PY_FILES" '^\s*(except\s*:|except\s+Exception\s*:)\s*pass\s*$'
  scan py "except-baseexception"   "$PY_FILES" '^\s*except\s+BaseException'
  scan py "noqa-no-reason"         "$PY_FILES" '#\s*(noqa|type:\s*ignore)(\s|$|:)' "(noqa|type:\\s*ignore)[^#]{0,200}$_HAS_REASON"
  scan py "inline-import"          "$PY_FILES" '^\s{4,}(import\s|from\s+\S+\s+import\s)'
  scan py "mutable-default-arg"    "$PY_FILES" 'def\s+\w+\([^)]*=\s*(\[\]|\{\}|set\(\))'
  scan py "==None/True/False"      "$PY_FILES" '==\s*(None|True|False)\b|\b(None|True|False)\s*=='
  scan py "range(len(...))"        "$PY_FILES" 'range\(len\('
  scan py "insecure-rng"           "$PY_FILES" 'random\.(random|choice|randint|sample)\('
  scan py "requests-no-timeout"    "$PY_FILES" '\brequests\.(get|post|put|delete|patch)\(' 'timeout\s*='
  scan py "httpx-no-timeout"       "$PY_FILES" '\bhttpx\.(get|post|put|delete|AsyncClient\(\s*\))' 'timeout\s*='
  scan py "f-string-into-sql"      "$PY_FILES" '\b(execute|executemany|query|run)\(\s*f["\x27]'
  scan py "f-string-into-shell"    "$PY_FILES" 'subprocess\.(run|Popen|check_output|check_call)\(\s*\[?\s*f["\x27]'
  scan py "todo-no-issue"          "$PY_FILES" '(#|//)\s*TODO(\s|:|$)' '(#[0-9]+|GH-[0-9]+|[A-Z]+-[0-9]+)'
  scan py "**kwargs-passthrough"   "$PY_FILES" 'def\s+\w+\([^)]*\*\*kwargs[^)]*\):\s*$'
fi

if [ -n "$PY_NON_TEST" ]; then
  scan py "assert-non-test"        "$PY_NON_TEST" '^\s*assert\s+'
  scan py "print-non-test"         "$PY_NON_TEST" '^\s*print\(' '#\s*noqa'
  scan py "time.sleep-non-test"    "$PY_NON_TEST" '^\s*(time\.sleep|await\s+asyncio\.sleep)\('
fi

if [ -n "$PY_NON_INFRA" ]; then
  scan py "os.environ.get"         "$PY_NON_INFRA" 'os\.environ\.(get|\[)'
fi

# ---------------------------------------------------------------------------
# TypeScript / JavaScript pass
# ---------------------------------------------------------------------------

if [ -n "$TS_FILES" ]; then
  scan ts "explicit-any"             "$TS_FILES" '(:|<|>|,|\()\s*any\b|\bas\s+any\b'
  scan ts "as-cast"                  "$TS_FILES" '\bas\s+[A-Z][A-Za-z0-9_<>]*' 'as\s+const\b|as\s+unknown\b'
  scan ts "non-null-assertion"       "$TS_FILES" '[a-zA-Z_$][a-zA-Z0-9_$]*!\.[a-zA-Z_$]'
  scan ts "loose-equality"           "$TS_FILES" '[^=!<>](==|!=)([^=]|$)'
  scan ts "Math.random"              "$TS_FILES" '\bMath\.random\('
  scan ts "eslint-disable-no-reason" "$TS_FILES" '(eslint-disable|@ts-ignore|@ts-nocheck)(\s|$|-)' "(eslint-disable|@ts-ignore|@ts-nocheck)[^/]{0,200}$_HAS_REASON"
  scan ts "fetch-no-signal"          "$TS_FILES" '\bfetch\(' 'signal\s*:|AbortSignal'
  scan ts "JSON.parse-bare"          "$TS_FILES" '\bJSON\.parse\('
  scan ts "empty-catch"              "$TS_FILES" '\.catch\(\s*\(\s*\)\s*=>\s*(\{\s*\}|null|undefined)\s*\)'
  scan ts "eval-or-Function"         "$TS_FILES" '\beval\(|new\s+Function\('
  scan ts "setTimeout-string"        "$TS_FILES" 'setTimeout\(\s*["\x27]'
  scan ts "banned-type"              "$TS_FILES" ':\s*(Function|Object)\b'
  scan ts "axios-import"             "$TS_FILES" '^\s*(import|const|let|var)\s.*\baxios\b'
  scan ts "todo-no-issue"            "$TS_FILES" '//\s*TODO' '(#[0-9]+|GH-[0-9]+|[A-Z]+-[0-9]+)'
fi

if [ -n "$TS_NON_TEST" ]; then
  scan ts "console.log-non-test"     "$TS_NON_TEST" '^\s*console\.(log|debug|info)\('
fi

if [ -n "$TS_NON_CONFIG" ]; then
  scan ts "process.env-non-config"   "$TS_NON_CONFIG" '\bprocess\.env\.[A-Z]'
fi

# ---------------------------------------------------------------------------
# Go pass
# ---------------------------------------------------------------------------

if [ -n "$GO_FILES" ]; then
  scan go "ignored-err"             "$GO_FILES" '^\s*_\s*,?\s*=\s*[a-zA-Z][A-Za-z0-9_.]*\(' 'if\s+_\s*='
  scan go "http.DefaultClient"      "$GO_FILES" '\bhttp\.DefaultClient\b'
  scan go "math/rand-import"        "$GO_FILES" '^\s*["\x27]math/rand["\x27]'
  scan go "fmt.Sprintf-into-sql"    "$GO_FILES" 'fmt\.Sprintf\([^)]*\b(SELECT|INSERT|UPDATE|DELETE)\b'
  # fmt.Errorf with `+ err.Error()` or without `%w` — both lose the chain.
  scan go "fmt.Errorf-no-wrap"      "$GO_FILES" 'fmt\.Errorf\([^)]*\+\s*[a-zA-Z_][a-zA-Z0-9_.]*\.Error\(\)|fmt\.Errorf\("[^"]*"[^%]*\b(err|e)\b\s*\)'
  scan go "nolint-no-reason"        "$GO_FILES" '//\s*nolint(\s|$|:)' "nolint[^/]{0,200}$_HAS_REASON"
  # `^\s+regexp\.MustCompile\(` — leading whitespace heuristic for "inside a
  # function body" (vs module-level `var foo = regexp.MustCompile(...)` which
  # starts at column 0). False positives when MustCompile is the first
  # statement of a function (rare and still flag-worthy).
  scan go "regexp-MustCompile-in-func" "$GO_FILES" '^\s+regexp\.MustCompile\('
  scan go "ioutil-deprecated"       "$GO_FILES" '\bioutil\.'
  scan go "empty-interface"         "$GO_FILES" '\binterface\s*\{\s*\}'
  scan go "todo-no-issue"           "$GO_FILES" '//\s*TODO' '(#[0-9]+|GH-[0-9]+|[A-Z]+-[0-9]+)'
  # NOTE: `defer-in-loop` and `go-func-fire-forget` are documented in
  # --list-patterns but not auto-scanned — a one-line regex flags every `for`
  # or `go func()`, ~80% false positive. Both need AST-aware tooling (`go vet
  # -vettool=loopvar` / `errgroup` audit). Flag manually during the prose pass.
fi

if [ -n "$GO_NON_TEST" ]; then
  scan go "panic-non-test"          "$GO_NON_TEST" '^\s*panic\('
  scan go "time.Sleep-non-test"     "$GO_NON_TEST" '\btime\.Sleep\('
  scan go "recover-bare"            "$GO_NON_TEST" '\brecover\(\)' 'panic\(|log\.|logger\.'
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
if [ "$HITS_TOTAL" -eq 0 ]; then
  echo "review-scan: clean (0 hits across $(echo "$CHANGED" | wc -l | tr -d ' ') changed files)"
  exit 0
else
  echo "review-scan: $HITS_TOTAL hit(s) — triage each as finding or justified-and-suppress"
  echo "             see code-craft SKILL.md > Review checklist > Fast pass > Mechanical scan"
  exit 1
fi
