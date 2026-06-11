# TDD workflow

Open this when writing new code (greenfield) or adding behavior to existing
code. Same discipline in Python and Go; tooling lives in `python.md` /
`golang.md`.

## The loop

Short and disciplined — one pass is minutes, not hours.

1. **Write a failing test** for the next slice of behavior.
2. **Run it.** Confirm it fails for the right reason (assertion, not a
   syntax/import error). A test that won't compile isn't a failing test.
3. **Write the minimum code to pass.** Resist anticipating the next test.
4. **Run all tests.** New one passes, nothing regressed.
5. **Refactor** — naming, helpers, duplication. Tests stay green throughout.
6. **Repeat.**

Skipping step 2 means you eventually find a test that always passed. Skipping
step 5 means tomorrow's code sits on today's first draft.

## "Next slice of behavior"

The smallest behavior worth a plain-language sentence — one test, one assertion
focus:

- "Returns the user when the id exists."
- "Returns `UserNotFoundError` when the id does not exist."
- "Wraps the underlying DB error when the query fails otherwise."
- "Closes the connection even if the query panics."

Don't assert five behaviors in one test — five named tests tell a future reader
the contract.

## Naming tests — the name **is** the spec

A reader scanning the test file should learn what the function does without
opening the implementation. The verbosity is the point — the list reads as a
contract.

```python
def test_get_user_returns_user_when_id_exists(): ...
def test_get_user_raises_user_not_found_when_id_missing(): ...
def test_get_user_wraps_db_error_in_repository_error(): ...
```

```go
func TestGetUser_ReturnsUserWhenIDExists(t *testing.T) { ... }
func TestGetUser_ReturnsErrUserNotFoundWhenIDMissing(t *testing.T) { ... }
func TestGetUser_WrapsDBErrorInRepositoryError(t *testing.T) { ... }
```

## Test isolation

Run order must be irrelevant; shared state between tests is a bug.

- No module-level globals that tests mutate.
- No "run this first because it sets up the DB" — setup lives in fixtures
  (pytest) or table setup (Go), not in ordering.
- Time, randomness, and external services are injected, not called directly. A
  test that passes Tuesday and fails Wednesday is flaky — almost always
  something non-deterministic leaked in.

## Unit vs integration — both required

They answer different questions.

- **Unit:** "does this entity work in isolation, given its deps' contract?"
  Fast (ms), run on save, substitute deps with a fake/stub implementing the
  same interface. Catch logic errors.
- **Integration:** "does it work wired to real deps?" Slower (seconds), run in
  CI, use real Postgres/Redis/HTTP via testcontainers. Catch contract drift
  between your code and the real system.

Only unit → fast to test, slow to debug in prod. Only integration → slow to
develop, fast to debug.

## What to test, what not

**Test:** the contract of every public function; every branch (branch
coverage, not just line); every error path (bugs live there, not on the happy
path); boundaries (empty, single, max, off-by-one); concurrency/timing/ordering
when the code promises them.

**Don't test:** private helpers in isolation (test through the public surface;
if a helper needs its own tests, make it public); third-party libs (trust them,
or wrap in an adapter and test the adapter against the contract you depend on);
config-loading boilerplate, trivial getters/setters, generated code.

## Integration tests with real dependencies

Use testcontainers (`testcontainers-python` / `testcontainers-go`) to spin up
real Postgres/Redis/NATS — starts in seconds, real wire-format, no fakery. Two
patterns:

- **Container per test** — max isolation, slower. For tests that mutate global
  state non-trivially.
- **Container per package, transactional rollback per test** — faster; each
  test runs in a transaction rolled back at teardown. Most relational-DB tests.

For HTTP, prefer `httptest.NewServer` (Go) or `pytest-httpx` recording mode
(Python) over hand-rolled mocks — recording once captures the real response
shape; hand mocks drift silently.

## Coverage

Run with branch coverage:

- Python: `pytest --cov=src --cov-branch --cov-report=term-missing`
- Go: `go test -race -covermode=atomic -coverprofile=coverage.out ./...`

Coverage trending down is a signal to investigate (deleted tests? untested new
code?), not a number to chase. And high coverage with shallow assertions is
worse than lower coverage with deep ones — `assert result is not None` after a
complex computation is theater; assert on actual structure and values.

## When TDD genuinely doesn't fit

- **Exploratory spikes** to learn a library — write it, throw it away, then TDD
  the real version.
- **UI rendering** where the assertion is "does this look right" — visual
  regression tools beat unit tests.
- **One-off scripts** run once and deleted — don't bring the apparatus for a
  30-line migration.

The default is TDD; the exceptions are exceptions, not loopholes.
