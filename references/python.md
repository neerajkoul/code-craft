# Python idioms

Language-specific guidance for the `SKILL.md` principles. Open this when writing
Python; cross-reference `golang.md` only if a decision spans both.

## Project layout

```
project/
├── pyproject.toml          # ruff, pytest, mypy config all live here
├── src/
│   └── project/
│       ├── __init__.py
│       ├── config.py       # constants and config loading; no logic
│       ├── domain/         # pure domain logic, no I/O
│       ├── adapters/       # one file per external dependency, behind an interface
│       └── handlers/       # entry points (HTTP, queue consumers, CLI)
└── tests/
    ├── unit/
    └── integration/
```

The `domain/` / `adapters/` / `handlers/` split is the open-closed principle in
physical form: domain code has no idea what database is in use, adapters know a
specific database, handlers wire the two.

## Type hints

Use everywhere — they're documentation the IDE and type checker verify. Run
`mypy --strict` in CI. Keep types simple:

```python
# Good — readable, precise, no cleverness.
def fetch_user(user_id: str) -> User | None:
    ...

# Avoid — generics layered on generics. If you find yourself reaching for
# TypeVar, ParamSpec, or Protocol generics in normal application code,
# step back. The type system is a tool, not a hobby.
def process[T: Hashable, U: Sized](items: Iterable[T], fn: Callable[[T], U]) -> dict[T, U]:
    ...
```

When you need a `Protocol`, define it next to the consumer, not the
implementation — the consumer owns the contract:

```python
# In src/project/domain/user_service.py
from typing import Protocol

class UserRepository(Protocol):
    def get(self, user_id: str) -> User | None: ...
    def save(self, user: User) -> None: ...

class UserService:
    def __init__(self, repo: UserRepository) -> None:
        self._repo = repo
    ...
```

The Postgres implementation lives in `adapters/postgres_user_repository.py`,
wired in at the edge.

## Exceptions

A small hierarchy of domain exceptions per module:

```python
class UserServiceError(Exception):
    """Base for user-service errors."""

class UserNotFoundError(UserServiceError):
    """Raised when a user lookup finds no record."""

class UserAlreadyExistsError(UserServiceError):
    """Raised when trying to create a user with a duplicate identifier."""
```

At an external-dependency boundary, catch the library's exception, log with
context, and raise a domain exception — application code never sees
`psycopg.errors.UniqueViolation` directly:

```python
def save(self, user: User) -> None:
    try:
        self._conn.execute(INSERT_USER_SQL, user.as_row())
    except psycopg.errors.UniqueViolation as exc:
        logger.warning(
            "duplicate user id on insert",
            extra={"user_id": user.id},
        )
        raise UserAlreadyExistsError(user.id) from exc
```

`from exc` preserves the chain. Always log enough context (user id, request id,
correlation id) to reconstruct what happened from logs alone.

A bare `except:` / `except Exception:` is almost always a bug. The only
legitimate use is the top of an event loop or worker — catch, log at error level
with the full traceback, re-enter the loop.

## Constants and configuration

Module constants in UPPER_SNAKE. Environment-varying config goes through
`config.py`, never scattered `os.environ.get`:

```python
# src/project/config.py
import os
from dataclasses import dataclass

DEFAULT_HTTP_TIMEOUT_SECONDS: float = 5.0
DEFAULT_MAX_RETRY_ATTEMPTS: int = 3
DEFAULT_CIRCUIT_BREAKER_OPEN_DURATION_SECONDS: float = 30.0

@dataclass(frozen=True, slots=True)
class Config:
    database_url: str
    redis_url: str
    http_timeout_seconds: float = DEFAULT_HTTP_TIMEOUT_SECONDS

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            database_url=os.environ["DATABASE_URL"],
            redis_url=os.environ["REDIS_URL"],
            http_timeout_seconds=float(
                os.environ.get("HTTP_TIMEOUT_SECONDS", DEFAULT_HTTP_TIMEOUT_SECONDS)
            ),
        )
```

`frozen=True, slots=True` gives an immutable, low-memory dataclass. Use
`slots=True` on hot-path data classes — it drops the per-instance `__dict__` and
noticeably reduces allocation in services creating many instances.

## Connection pools

Create at startup, share across the process, inject via DI — never a global
import, never a one-off connection per request.

**Postgres (asyncpg).**

```python
import asyncpg

DEFAULT_DB_POOL_MIN_SIZE: int = 5
DEFAULT_DB_POOL_MAX_SIZE: int = 20
DEFAULT_DB_COMMAND_TIMEOUT_SECONDS: float = 5.0

pool = await asyncpg.create_pool(
    dsn=config.database_url,
    min_size=DEFAULT_DB_POOL_MIN_SIZE,
    max_size=DEFAULT_DB_POOL_MAX_SIZE,
    command_timeout=DEFAULT_DB_COMMAND_TIMEOUT_SECONDS,
)
```

**HTTP (httpx)** — one client per process, reused; each instance has its own
pool.

```python
client = httpx.AsyncClient(
    timeout=httpx.Timeout(DEFAULT_HTTP_TIMEOUT_SECONDS),
    limits=httpx.Limits(max_connections=100, max_keepalive_connections=20),
)
```

**Redis (redis-py)** — async client with a pool.

```python
redis_pool = redis.asyncio.ConnectionPool.from_url(
    config.redis_url,
    max_connections=DEFAULT_REDIS_POOL_MAX_SIZE,
)
redis_client = redis.asyncio.Redis(connection_pool=redis_pool)
```

## Memory and allocation

- `slots=True` on hot-path dataclasses.
- Generators (`yield`) over building intermediate lists you immediately iterate.
- `array.array` / `numpy.ndarray` over `list[int]` for homogeneous numeric
  arrays — lower per-element overhead.
- String building in loops → accumulate to a list and `"".join(...)`. Repeated
  `s += part` is O(n²) (immutability).
- `io.BytesIO` / `io.StringIO` as reusable staged buffers.

For long-running workers accumulating fragmentation (CPython can't compact
arenas), recycle the worker process every N tasks — a fresh fork is paid once,
fragmentation grows forever.

## Streaming over regex

Regex is fine when readability beats performance and input is small. For large
inputs / hot paths, write a streaming parser:

```python
# Bad — regex compiled in the loop, O(n) compilations.
def extract_ids(lines: Iterable[str]) -> Iterator[str]:
    for line in lines:
        match = re.search(r"id=(\w+)", line)  # recompiled every iteration
        if match:
            yield match.group(1)

# Better — compile once at module load.
ID_PATTERN = re.compile(r"id=(\w+)")

def extract_ids(lines: Iterable[str]) -> Iterator[str]:
    for line in lines:
        match = ID_PATTERN.search(line)
        if match:
            yield match.group(1)

# Best for hot paths — no regex at all.
ID_PREFIX = "id="

def extract_ids(lines: Iterable[str]) -> Iterator[str]:
    for line in lines:
        idx = line.find(ID_PREFIX)
        if idx == -1:
            continue
        end = line.find(" ", idx)
        yield line[idx + len(ID_PREFIX) : end if end != -1 else len(line)]
```

The "best" version is uglier but materially faster for high-volume pipelines.

## Database batching

`executemany` for batched inserts; `COPY` (an order of magnitude faster) for
very large ones:

```python
async def bulk_insert_users(pool: asyncpg.Pool, users: list[User]) -> None:
    rows = [(u.id, u.email, u.created_at) for u in users]
    async with pool.acquire() as conn:
        await conn.copy_records_to_table(
            "users",
            records=rows,
            columns=["id", "email", "created_at"],
        )
```

For reads, multi-key fetch via `IN (...)` or `= ANY($1)`, not per-key
round-trips. For Redis, pipeline whenever you have >1 command — N piped commands
are one round-trip, N un-piped are N:

```python
async with redis_client.pipeline(transaction=False) as pipe:
    for key in keys:
        pipe.get(key)
    values = await pipe.execute()
```

## Testing

`pytest`. Fixtures over `setUp`/`tearDown`. Parametrize over copy-pasted tests:

```python
import pytest

@pytest.mark.parametrize(
    "input_value, expected",
    [
        ("", 0),
        ("a", 1),
        ("hello", 5),
    ],
)
def test_string_length(input_value: str, expected: int) -> None:
    assert len(input_value) == expected
```

Integration vs Postgres → `testcontainers-python`. HTTP → record a fixture with
`pytest-httpx` over ad-hoc mocking. Code using current time → freeze with
`freezegun` or inject a clock; never let `datetime.now()` leak into the
assertion.

```bash
pytest --cov=src/project --cov-branch --cov-report=term-missing
```

`--cov-branch` is non-negotiable — line coverage hides untested if-branches.

## Tooling

- **Ruff** for lint + format (replaces `black`, `isort`, `flake8`, most of
  `pylint` in one fast tool). Configure in `pyproject.toml`.
- **mypy** `--strict`. Bend it (`# type: ignore[<rule>]` with a why-comment)
  only when the type system genuinely can't express what you mean.
- **pip-audit** / **safety** for dependency scanning in CI.

`scripts/lint.sh` runs ruff format, ruff check, and mypy in sequence, exiting
non-zero on any failure.
