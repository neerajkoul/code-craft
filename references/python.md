# Python idioms

Language-specific guidance for `SKILL.md`. Open when writing Python.

## Project layout

```
project/
├── pyproject.toml          # ruff, pytest, mypy config
├── src/project/
│   ├── config.py           # constants and config loading; no logic
│   ├── domain/             # pure domain logic, no I/O
│   ├── adapters/           # one file per external dependency, behind an interface
│   └── handlers/           # entry points (HTTP, queue consumers, CLI)
└── tests/{unit,integration}/
```

Domain code has no idea what database is in use; adapters know a specific database; handlers wire the two. The split is the open-closed principle in physical form.

## Type hints

Everywhere; `mypy --strict` in CI. Keep types simple — `def fetch_user(user_id: str) -> User | None` good; layered `TypeVar`/`ParamSpec`/`Protocol` generics in normal application code = step back. The type system is a tool, not a hobby.

**`Protocol` interfaces live next to the consumer, not the implementation** — the consumer owns the contract:

```python
# src/project/domain/user_service.py
class UserRepository(Protocol):
    def get(self, user_id: str) -> User | None: ...
    def save(self, user: User) -> None: ...
```

The Postgres implementation lives in `adapters/` and is wired at the edge.

## Validation at boundaries — Pydantic

**Pydantic for every untrusted input crossing a boundary**: HTTP bodies, queue messages, LLM tool args, webhooks, config files. Type hints catch developer mistakes at edit time; Pydantic catches caller mistakes at runtime.

```python
class CreateUserRequest(BaseModel):
    email: EmailStr
    display_name: str = Field(min_length=1, max_length=80)
    age: int = Field(ge=13, le=130)
    referral_code: str | None = Field(default=None, pattern=r"^[A-Z0-9]{6,12}$")
```

Discipline:

- **Parse, don't validate.** `Model.model_validate(payload)` at the edge; downstream code trusts the type and stops re-checking.
- **Narrow types, not strings.** `EmailStr`, `HttpUrl`, `IPvAnyAddress`, `SecretStr`, `Decimal`, `datetime`. A `str` field that should be an email is doing half the job.
- **`Field(...)` constraints** for length/range/pattern/default — visible to OpenAPI, IDE, and the next reader; handler-buried checks are not.
- **`@model_validator(mode="after")`** for cross-field rules ("if X then Y must be set"); don't smear across the handler.
- **`ConfigDict(extra="forbid")` on inbound models.** Unknown fields are caller mistakes; reject loudly. `extra="ignore"` only for explicitly versioned-forward schemas.
- **`frozen=True` for value objects** flowing further into the system.
- **Pydantic v2 only.** v1 is EOL; no `pydantic.v1` imports unless stuck integrating.
- **Hot-path cost:** instantiate the validator once at module load (`TypeAdapter(MyModel)`) when re-parsing the same shape per request. Internal trusted data: dataclasses or plain types — Pydantic is for the boundary.
- **FastAPI validates request-model params for you — don't double-validate.** Non-FastAPI handlers (queue consumers, webhooks, CLI) call `model_validate` explicitly at entry.

## Exceptions

Small domain hierarchy per module (`UserServiceError` base; `UserNotFoundError`, `UserAlreadyExistsError` subclasses). At the dependency boundary: catch the library exception, log with context, raise the domain exception with `from exc`:

```python
def save(self, user: User) -> None:
    try:
        self._conn.execute(INSERT_USER_SQL, user.as_row())
    except psycopg.errors.UniqueViolation as exc:
        logger.warning("duplicate user id on insert", extra={"user_id": user.id})
        raise UserAlreadyExistsError(user.id) from exc
```

Application code never sees `psycopg.errors.UniqueViolation`. `from exc` preserves the chain; log enough context (user id, request id, correlation id) to reconstruct from logs alone.

Bare `except:` / `except Exception:` is almost always a bug. The only legitimate site is the very top of an event loop or worker — catch, log at error with full traceback, re-enter the loop.

### try / except / finally — not try / finally

Bare `try: ... finally:` (no `except`) means cleanup runs but the failure propagates with zero context — caller sees the raw library exception, logs lack `error_type` / `error` / `correlation_id`. Add the observation branch:

```python
try:
    self._conn.execute(SQL, args)
except psycopg.errors.UniqueViolation as exc:
    logger.warning("duplicate user id", extra={"user_id": user.id, "error_type": type(exc).__name__})
    raise UserAlreadyExistsError(user.id) from exc
except psycopg.errors.OperationalError as exc:
    logger.error("db operational error", extra={"error": str(exc), "error_type": type(exc).__name__})
    raise
finally:
    self._release_lock()
```

Rules:

- **`try` + `finally` alone is a smell.** Ask: which failure mode is being swallowed? "None, the caller handles it" is rarer than the pattern's frequency suggests.
- **One exception type per `except`**, narrowest that can actually be raised. Catch-all-and-re-raise belongs at the worker loop top only.
- **Bare `raise` re-raises with the original traceback; `raise X() from exc` wraps.** Never `from None` — it loses the original.
- **`finally` is for resource release, not error recovery.** One or two cleanup calls; if cleanup itself is fallible, wrap each fallible call in its own try/except inside `finally` and log. A `finally` that raises masks the outer exception.
- **Context managers beat manual try/finally** where they exist: `with conn.transaction():`, `async with self._lock:`, `with open(path) as f:`.
- **`asyncio.CancelledError`:** catch only where cleanup is needed, re-raise immediately. Silencing it breaks cooperative cancellation.

## Comment & docstring format

### Docstrings — PEP 257 + Google style

```python
def fetch_user(user_id: str, *, include_deleted: bool = False) -> User | None:
    """Look up a user by id.

    Args:
        user_id: Caller-side ULID; ``len() == 26``.
        include_deleted: If ``True``, returns soft-deleted rows. Admin paths only.

    Returns:
        The user row, or ``None`` if not found.

    Raises:
        UserRepositoryError: On any underlying DB failure; original preserved via ``from``.
    """
```

- First line: single-sentence imperative summary, <~72 chars, blank line after.
- Body for any non-trivial signature; Args/Returns/Raises in Google or NumPy style — one per repo, don't mix.
- Triple double-quotes always.
- **No type info in the docstring** — types live in the signature; document the *semantic* contract ("ULID, len == 26"), not the type.
- **Document side effects** (commits, cache mutation, event publishes) — that's the contract the caller needs.
- Don't paraphrase the body; if the signature already says it, skip.

### Inline comments — why, not what

Bar: "would removing this make a reader re-derive the constraint?"

```python
ttl = max(remaining_seconds, _MIN_TTL_SECONDS)  # Slack rate-limits sub-second TTLs.
```

- Full sentences; `.` if more than a clause.
- **`# noqa: <RULE> — <reason>`** — bare `# noqa` is a smell. Same for `# type: ignore[<rule>] — <reason>` and `# nosec <RULE> — <reason>`. Rule code says *what was suppressed*; reason says *whether to undo it*.
- **`# TODO(@author, YYYY-MM-DD): description`** — bare TODO rots; author + date forces accountability and lets grep audit aging.
- **No commented-out code in committed files.** Git remembers.

## Configuration — `pydantic-settings`

**`BaseSettings` for env config** — typed, validated, one place. Scattered `os.environ.get(...)` is config drift (one path reads `RATE_LIMIT_QPS` as int, another as `str("0")`, one silently no-ops).

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CLAW_", env_file=".env", extra="forbid", frozen=True,
    )
    database_url: PostgresDsn          # required — fail boot if missing
    redis_url: RedisDsn
    api_key: SecretStr                 # redacted in repr/logs
    http_timeout_seconds: float = Field(default=5.0, gt=0)
    db_pool_min_size: int = Field(default=5, ge=1)
    db_pool_max_size: int = Field(default=20, ge=1)
    max_retry_attempts: int = Field(default=3, ge=1, le=10)

@lru_cache
def get_settings() -> Settings:
    return Settings()
```

Discipline:

- **One `Settings` class per process.** Sub-services inherit and add fields.
- **`env_prefix` is mandatory** — otherwise a sibling tool's `DATABASE_URL` leaks in.
- **`extra="forbid"`** — a `CLAW_DATABASE_URLL` typo silently falls back to default without it; with it, boot fails loudly.
- **`SecretStr`** for anything that shouldn't appear in logs/tracebacks; `.get_secret_value()` only at the use site.
- **`frozen=True`** — immutable post-boot.
- **`@lru_cache` accessor** — env read once; tests call `get_settings.cache_clear()` in a fixture.
- **`Field(gt=, ge=, le=)` bounds** — a boot-time validation error beats a 3am incident over a negative pool size from a CI env bug.
- **Computed defaults** via `model_validator(mode="after")` ("if A unset, derive from B").
- **No `os.environ.get(...)` outside `config.py`** — the positive form of the SKILL.md fingerprint.
- TOML/YAML/multi-source via `customise_sources` only when actually needed.

## Memory, arenas, and fragmentation

Three load-bearing CPython facts:

1. **Small objects (≤512 bytes) come from `pymalloc`** — slab allocator, 256 KiB arenas, pools of one size class per page. Large objects go to the system allocator.
2. **An arena cannot be returned to the OS until *every* object in it is freed.** A worker that allocates one 100 MB peak batch holds the 100 MB resident even after `gc.collect()` — each arena has a survivor pinning it.
3. **No compaction.** Java/Go/.NET move objects to defragment; CPython cannot. Fragmentation only grows.

### Write-time tactics

- **`__slots__` / `@dataclass(slots=True)`** on any class created at >~1,000 instances per process lifetime — drops the ~56-byte per-instance `__dict__` and locks the attribute set.
- **Generators over materialized lists** when no random access is needed — one frame vs N objects.
- **`array.array` / `numpy.ndarray` over `list[int]`** for homogeneous numerics — ~6× less memory per element.
- **`bytes`/`bytearray` over `str` for binary payloads** — decode/re-encode round-trips double memory plus copy cost.
- **`memoryview` over `buf[a:b]`** for windows — slicing copies; never slice-copy 100 MB to read 10 bytes.
- **`io.BytesIO` reuse** — `buf.seek(0); buf.truncate(0)` recycles; throw-away-and-reallocate fragments.
- **`weakref.WeakValueDictionary` / size-capped LRU / TTL** for caches keyed by user input — the alternative is an unbounded dict and an OOM.
- **Closure discipline.** A closure captures its whole lexical scope; if it outlives the request, the request graph stays resident. Extract needed fields *before* the `await`.
- **String building:** accumulate to a list + `"".join(...)`; `s += part` is O(n²).

### Runtime / deployment tactics

- **Worker recycling — the single most effective pattern.** gunicorn `--max-requests`, uvicorn `--limit-max-requests`, Celery `worker_max_tasks_per_child`. One-time fork cost; resets every arena. **Don't fight fragmentation in code — recycle.**
- **`gc.freeze()` after startup** — marks the startup heap permanent so the generational GC stops scanning it. Call once after imports, before traffic.
- **`gc.set_threshold(...)`** — defaults (700, 10, 10) are tuned for short scripts; long-lived high-churn workers often benefit from raising — with profiling evidence only.
- **`PYTHONMALLOC=malloc`** — swap pymalloc for the system allocator when pairing with a jemalloc/mimalloc `LD_PRELOAD`. Not a default; measure first.
- **Avoid `__del__`** — finalizers create GC-unbreakable cycles. `weakref.finalize(obj, cleanup_fn)` instead.
- **Profile, don't guess.** `tracemalloc` snapshots, `memray` flamegraphs, `resource.getrusage(...).ru_maxrss` for RSS over time. Arena non-release is invisible to `gc.get_objects()`; it shows in RSS.

### Pattern: bounded streaming pipeline

```python
async def process_uploads(stream: AsyncIterator[bytes]) -> None:
    async for chunk in stream:              # bounded by upstream
        for row in _parse_chunk(chunk):     # generator, no list
            await _persist_row(row)         # row freed next loop
```

Principle: peak memory ≈ working-set memory, not cumulative-input memory. The list-of-250k-dicts version OOMs; the generator version peaks at one row.

## Constants and value objects

Module-level UPPER_SNAKE constants at the top of the file that consumes them — not a `constants.py` junk drawer:

```python
DEFAULT_HTTP_TIMEOUT_SECONDS: float = 5.0
DEFAULT_MAX_RETRY_ATTEMPTS: int = 3
DEFAULT_CIRCUIT_BREAKER_OPEN_DURATION_SECONDS: float = 30.0
```

Env-overridable constants live on `Settings`, not duplicated in UPPER_SNAKE — pick one home.

Internal value objects (DTOs, message envelopes): `@dataclass(frozen=True, slots=True)` — immutable, low-memory.

## Connection pools

Created at startup, shared across the process, injected into handlers — never imported as a global, never opened per request.

```python
# Postgres (asyncpg)
pool = await asyncpg.create_pool(
    dsn=config.database_url, min_size=5, max_size=20, command_timeout=5.0,
)

# HTTP (httpx) — one client per process; each AsyncClient owns its pool
client = httpx.AsyncClient(
    timeout=httpx.Timeout(5.0),
    limits=httpx.Limits(max_connections=100, max_keepalive_connections=20),
)

# Redis (redis-py async)
redis_client = redis.asyncio.Redis(
    connection_pool=redis.asyncio.ConnectionPool.from_url(config.redis_url, max_connections=50),
)
```

## Streaming over regex

Regex when readability beats performance and input is small. Compile once at module load (`ID_PATTERN = re.compile(r"id=(\w+)")`) — never inside the loop. For hot paths over large inputs, drop regex for `str.find` / slicing — uglier, materially faster:

```python
ID_PREFIX = "id="
def extract_ids(lines: Iterable[str]) -> Iterator[str]:
    for line in lines:
        idx = line.find(ID_PREFIX)
        if idx == -1:
            continue
        end = line.find(" ", idx)
        yield line[idx + len(ID_PREFIX) : end if end != -1 else len(line)]
```

## Database batching

- Batched inserts: `executemany`; very large inserts: Postgres `COPY` via `conn.copy_records_to_table(...)` — an order of magnitude faster than parameterized inserts.
- Multi-key reads: `IN (...)` / `= ANY($1)`, not per-key round-trips.
- Redis: pipeline whenever >1 command — `async with redis_client.pipeline(transaction=False) as pipe: ...` — N commands, one round-trip.

## Testing

`pytest`. Fixtures over `setUp`/`tearDown`; `@pytest.mark.parametrize` over copy-pasted tests. Integration against real Postgres via `testcontainers-python`; HTTP via `pytest-httpx` recorded fixtures over ad-hoc mocks. Time: freeze with `freezegun` or inject a clock — never let `datetime.now()` leak into assertions.

```bash
pytest --cov=src/project --cov-branch --cov-report=term-missing
```

`--cov-branch` is non-negotiable — line coverage hides untested if-branches.

## Tooling — PEP 8 / Ruff / mypy

PEP 8 is the floor; Ruff enforces it (replaces black + isort + flake8 + most-of-pylint; one binary, ~100× faster).

```toml
[tool.ruff]
line-length = 100               # PEP 8 says 79; 100 is the modern default. Match the team.
target-version = "py312"

[tool.ruff.lint]
select = [
    "E", "W",   # pycodestyle
    "F",        # pyflakes — undefined names, unused imports
    "I",        # isort
    "B",        # bugbear — common bugs
    "C4",       # comprehensions
    "UP",       # pyupgrade
    "SIM",      # simplify
    "RUF",      # ruff-specific
    "ASYNC",    # async footguns
    "S",        # bandit security
    "N",        # pep8-naming
    "PT",       # pytest-style
    "RET",      # return consistency
    "TID",      # tidy-imports
]
ignore = ["E501"]  # line length handled by formatter

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
```

PEP 8 essentials: 4-space indent, no tabs. `snake_case` functions/vars/modules, `PascalCase` classes, `UPPER_SNAKE` constants, `_private`, `__dunder__` reserved. Imports stdlib → third-party → first-party, blank line between groups, alphabetical within (`I` enforces). Two blank lines between top-level defs, one between methods. No wildcard imports. Line length 88–100, applied via the formatter.

Other tools: **mypy `--strict`** (bend with `# type: ignore[<rule>]` + reason only when the type system genuinely can't express it); **pip-audit** or **safety** in CI; bandit ships inside Ruff via `S`.

`scripts/lint.sh` runs ruff format, ruff check, mypy in sequence; non-zero on any failure.
