# TDD workflow

Open when writing new code or adding behavior to existing code. Same discipline in Python and Go; tooling in `python.md` / `golang.md`.

## The loop

One pass takes minutes, not hours.

1. **Write a failing test** for the next slice of behavior.
2. **Run it. Confirm it fails for the right reason** — assertion failure, not a syntax/import error. A test that fails to compile is not a meaningful failing test.
3. **Write the minimum code to pass.** Don't anticipate the next test.
4. **Run all tests.** New one passes, nothing regressed.
5. **Refactor.** Naming, extract helpers, dedupe — tests stay green through every step.
6. **Repeat.**

Skipping step 2 ("of course it would fail") eventually produces a test that always passes. Skipping step 5 builds tomorrow's code on today's first draft.

## What a "slice" looks like

The smallest behavior worth a plain-language sentence: "Returns the user when the id exists." / "Returns `UserNotFoundError` when it doesn't." / "Wraps the underlying DB error." / "Closes the connection even if the query panics."

One slice = one test, one assertion focus. Five behaviors = five tests with descriptive names, not one test with five asserts.

## Naming tests

The test name **is** the spec — the test list reads as the contract:

```python
def test_get_user_returns_user_when_id_exists(): ...
def test_get_user_raises_user_not_found_when_id_missing(): ...
def test_get_user_wraps_db_error_in_repository_error(): ...
```

```go
func TestGetUser_ReturnsUserWhenIDExists(t *testing.T) { ... }
func TestGetUser_ReturnsErrUserNotFoundWhenIDMissing(t *testing.T) { ... }
```

The verbosity is the point.

## Test isolation

Tests must not depend on each other; run order is irrelevant; shared state between tests is a bug.

- No module-level globals that tests mutate.
- No "run this first because it sets up the DB" — setup lives in fixtures (pytest) or table setup (Go), not ordering.
- Time, randomness, and external services are injected, not called directly. A test that passes Tuesday and fails Wednesday leaked non-determinism.

## Unit vs integration

Both required — different questions.

- **Unit:** "does this entity work in isolation, given its dependencies' contracts?" Milliseconds, run on save, dependencies replaced by fakes/stubs implementing the same interface.
- **Integration:** "does it work wired to real dependencies?" Seconds, run in CI, real Postgres / Redis / HTTP via testcontainers.

Unit tests catch logic errors; integration tests catch contract drift. Only-unit = fast to test, slow to debug in production. Only-integration = slow to develop.

## What to test / not test

**Test:** the contract of every public function; every branch (branch coverage, not line); every error path (where the bugs live); boundary edge cases (empty, single item, max size, off-by-one); concurrency/timing/ordering when promised.

**Don't test:** private helpers in isolation (test through the public surface; a helper needing its own tests probably wants extraction); third-party libraries (trust, or wrap in an adapter and test the adapter); config-loading boilerplate, logic-free getters/setters, generated code.

## Integration tests with real dependencies

Testcontainers (`testcontainers-python` / `testcontainers-go`) for real Postgres, Redis, NATS — start, run, tear down. Two patterns:

- **Container per test:** maximum isolation, slower. For non-trivial global-state mutation.
- **Container per package + transactional rollback per test:** faster; suitable for most relational-DB tests.

For HTTP, prefer `httptest.NewServer` (Go) or `pytest-httpx` recording mode (Python) over hand-rolled mocks — recording once captures the real response shape; hand mocks drift silently.

## Coverage

Branch coverage on:

- Python: `pytest --cov=src --cov-branch --cov-report=term-missing`
- Go: `go test -race -covermode=atomic -coverprofile=coverage.out ./...`

Coverage trending down is a signal to investigate, not a number to chase — a PR dropping 5% is deleting tests, adding untested code, or both. But high coverage with shallow assertions is worse than lower with deep ones: `assert result is not None` after a complex computation is theater; assert on actual structure and values.

## When TDD genuinely does not fit

- **Exploratory spikes** to learn a library — write, throw away, then TDD the real version.
- **UI rendering** where the assertion is "does this look right" — visual regression tools.
- **One-off scripts** run once and deleted.

The default is TDD. These are exceptions, not loopholes.
