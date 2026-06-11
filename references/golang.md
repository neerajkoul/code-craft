# Go idioms

Language-specific guidance for `SKILL.md`. Open when writing Go.

## Project layout

```
project/
├── go.mod
├── cmd/service/main.go     # tiny: parse config, wire dependencies, start server
├── internal/
│   ├── config/
│   ├── domain/             # pure domain logic, no I/O, no SQL
│   ├── adapters/           # one package per external dependency (postgres/, redis/, http/)
│   └── handlers/           # HTTP handlers, queue consumers, CLI commands
└── pkg/                    # only for genuinely module-external libraries
```

`internal/` is compiler-enforced — use it liberally; `pkg/` only for a genuinely public API. `main.go` loads config, instantiates adapters, injects into domain, starts the server — anything more belongs deeper in.

## Errors

```go
var (
    ErrUserNotFound      = errors.New("user not found")
    ErrUserAlreadyExists = errors.New("user already exists")
)

func (r *PostgresUserRepository) Save(ctx context.Context, user User) error {
    _, err := r.db.ExecContext(ctx, insertUserSQL, user.ID, user.Email)
    if err != nil {
        var pgErr *pgconn.PgError
        if errors.As(err, &pgErr) && pgErr.Code == pgerrcode.UniqueViolation {
            return fmt.Errorf("save user %s: %w", user.ID, ErrUserAlreadyExists)
        }
        return fmt.Errorf("save user %s: %w", user.ID, err)
    }
    return nil
}
```

Callers use `errors.Is(err, ErrUserAlreadyExists)` without depending on the wrapping string.

- Always check errors. `_ = something()` is a smell; a comment must explain why ignoring is correct.
- Wrap with `%w` + what-was-being-attempted when crossing a layer boundary.
- No panic in library code — panic is for unrecoverable programmer errors, not input validation.
- `defer` cleanup the moment the resource is acquired.
- `errors.Is(err, context.Canceled)` distinguishes "asked to stop" from "work failed" — log `Canceled` at `info`, real failures at `error`.

### `defer` is Go's `try/finally` — same trap

Bare `defer fn()` drops `fn`'s error silently. The parallel to try/except/finally is *defer + named return + error wrapping*:

```go
func Write(path string, data []byte) (err error) {
    f, err := os.Create(path)
    if err != nil {
        return fmt.Errorf("create %s: %w", path, err)
    }
    defer func() {
        if cerr := f.Close(); cerr != nil && err == nil {
            err = fmt.Errorf("close %s: %w", path, cerr)
        }
    }()
    if _, err = f.Write(data); err != nil {
        return fmt.Errorf("write %s: %w", path, err)
    }
    return nil
}
```

Rules:

- **`defer fn()` alone is a `finally` with no `except`.** If `fn()` can fail in a way the caller cares about (file flush, tx commit, network close), wrap and check.
- **Named return** — the deferred closure runs *after* the return value is set; mutate it through the named return.
- **`Close()` on writers is fallible** — buffered I/O flushes on Close; the flush error only surfaces there. Always check.
- **Defers run LIFO** — matters for paired acquisitions.
- **No `defer` inside a loop** — each iteration's defer queues until function return; open-1000-files-then-close-1000 is an fd pileup. Wrap the loop body in its own function.

## Interfaces

Define at the consumer, not the producer:

```go
// internal/domain/user_service.go
type UserRepository interface {
    Get(ctx context.Context, userID string) (User, error)
    Save(ctx context.Context, user User) error
}
```

The Postgres struct in `internal/adapters/postgres/` implements it structurally — no declaration; `main.go` wires them. Keep interfaces small: one method is often right, ten is usually wrong — a god interface is a renamed struct, not an abstraction.

## Validation at boundaries — go-playground/validator

Go's Pydantic parallel: bind inbound JSON/form/query into a struct with `validate:"..."` (raw validator.v10) or `binding:"..."` (Gin) tags, validate once at the edge, then trust the type.

```go
type CreateUserRequest struct {
    Email        string `json:"email"         validate:"required,email"`
    DisplayName  string `json:"display_name"  validate:"required,min=1,max=80,printascii"`
    Age          int    `json:"age"           validate:"required,gte=13,lte=130"`
    ReferralCode string `json:"referral_code,omitempty" validate:"omitempty,len=6|len=12,alphanum"`
}

var validate = validator.New(validator.WithRequiredStructEnabled())
```

Discipline:

- **One validator instance per process** — `validator.New()` caches compiled tag rules; per-request instantiation burns hot-path CPU.
- **Custom tags** via `validate.RegisterValidation("ulid", ...)` for project shapes; don't re-implement length/regex/range.
- **Struct-level validators** (`RegisterStructValidation`) for cross-field rules — same as Pydantic's `model_validator(mode="after")`.
- **Wrap `validator.ValidationErrors`** into your domain error at the handler — callers shouldn't import validator/v10.
- **Don't mix `binding:` and `validate:` in one struct** — two divergent error shapes.
- gRPC inbound: `protovalidate-go` (CEL in `.proto`). Same principle: bounds on the schema, validate once at the edge.

## Constants and configuration

Related constants in `const` blocks at the top of the file/package:

```go
const (
    DefaultHTTPTimeoutSeconds         = 5
    DefaultMaxRetryAttempts           = 3
    DefaultCircuitBreakerOpenDuration = 30 * time.Second
    DefaultDBPoolMaxOpenConns         = 25
    DefaultDBPoolMaxIdleConns         = 10
    DefaultDBConnMaxLifetime          = 5 * time.Minute
)
```

Config: parsed once at startup into a typed struct. `caarlos0/env` or `kelseyhightower/envconfig` — Go's pydantic-settings parallel:

```go
type Settings struct {
    DatabaseURL string `env:"CLAW_DATABASE_URL,required"`
    RedisURL    string `env:"CLAW_REDIS_URL,required"`
    // unset clears env after parse — keeps the secret out of /proc/self/environ.
    APIKey string `env:"CLAW_API_KEY,required,unset"`
    HTTPTimeout      time.Duration `env:"CLAW_HTTP_TIMEOUT"       envDefault:"5s"`
    DBPoolMaxOpen    int           `env:"CLAW_DB_POOL_MAX_OPEN"   envDefault:"25" validate:"gte=1,lte=200"`
    MaxRetryAttempts int           `env:"CLAW_MAX_RETRY_ATTEMPTS" envDefault:"3"  validate:"gte=1,lte=10"`
}
// Load() wraps env.Parse + validate.Struct in sync.Once; returns cached pointer + loadErr.
```

Discipline:

- **One `Settings` struct per process** — a second is config drift; namespace via embedding instead.
- **Service prefix (`CLAW_`) on every env var** — otherwise a sibling's `DATABASE_URL` leaks in.
- **`required` fails boot loudly; `unset` keeps secrets out of `/proc/self/environ`** and inherited children.
- **Validate the parsed struct at boot** — a CI bug setting `DB_POOL_MAX_OPEN=-1` should fail boot, not the first DB call.
- **`sync.Once` accessor** — parse once, load-failure visible exactly once.
- **No `os.Getenv` outside the config package** — positive form of the SKILL.md fingerprint.
- Multi-source (env + YAML + flags): `spf13/viper`, at the cost of opaque precedence — only when actually needed.

## Connection pools

```go
// Postgres (pgx)
poolConfig, _ := pgxpool.ParseConfig(cfg.DatabaseURL)
poolConfig.MaxConns = DefaultDBPoolMaxOpenConns
poolConfig.MinConns = DefaultDBPoolMinOpenConns
poolConfig.MaxConnLifetime = DefaultDBConnMaxLifetime
pool, err := pgxpool.NewWithConfig(ctx, poolConfig)

// HTTP — one *http.Client per process with explicit Transport.
// NEVER http.DefaultClient: no timeout, shared state.
var sharedHTTPClient = &http.Client{
    Timeout: DefaultHTTPTimeoutSeconds * time.Second,
    Transport: &http.Transport{
        MaxIdleConns: 100, MaxIdleConnsPerHost: 20, IdleConnTimeout: 90 * time.Second,
    },
}

// Redis (go-redis) — read/write timeouts are critical; without them a
// stuck connection holds a goroutine forever.
redisClient := redis.NewClient(&redis.Options{
    Addr: cfg.RedisAddr, PoolSize: 50, MinIdleConns: 10,
    DialTimeout: 2 * time.Second, ReadTimeout: 500 * time.Millisecond, WriteTimeout: 500 * time.Millisecond,
})
```

## Memory and allocation

- **`sync.Pool`** for high-frequency ephemerals — buffers, encoders, large per-call structs. `Get`, `defer { Reset(); Put() }`.
- **Pre-size slices and maps:** `make([]T, 0, n)`, `make(map[K]V, n)` — skips grow-and-rehash.
- **`strings.Builder`** for concatenation in loops; `s += part` allocates each time. `bytes.Buffer.Reset()` over a fresh buffer.
- **No reflection on hot paths.** `encoding/json` reflection is fine for control planes; data planes use code-generated marshalers (`easyjson`, `jsoniter`, `sonic`) — pays for itself at >10k req/s.
- **Large structs by pointer, small by value** — copy is the cost, not indirection.
- **Slice retention bug:** a slice over a 100 MB buffer keeps it all alive. Copy out: `out := append([]byte(nil), src[:10]...)`.

### Escape analysis, GC pressure, `GOMEMLIMIT`

- **`go build -gcflags="-m"`** prints escape decisions. A `&Local{}` that escapes is one heap allocation per call; returned by value it stays on the stack. Audit and reshape hot paths.
- **`pprof` heap profile** (`/debug/pprof/heap`, `-test.memprofile`) attributes allocations to call sites — focus on the top of the flamegraph.
- **`GOMEMLIMIT`** (Go 1.19+): soft ceiling at ~90% of the container limit so the GC ramps before the OOM killer fires. Without it Go assumes the host is yours.

Arena non-release (Python's problem) doesn't apply — the Go runtime returns pages to the OS — but unbounded growth keyed on user input is just as fatal: every cache and map needs a size cap or TTL.

## Concurrency

- **Every goroutine has a known exit.** No stop signal = leak.
- **`context.Context` first argument** for anything that does I/O or blocks. Cancel on shutdown, request abort, deadline.
- **`errgroup.Group`** for fanout that can fail — cancels siblings on first failure:

  ```go
  g, ctx := errgroup.WithContext(ctx)
  for _, item := range items {
      item := item
      g.Go(func() error { return processItem(ctx, item) })
  }
  if err := g.Wait(); err != nil { return fmt.Errorf("process items: %w", err) }
  ```

- **No shared state without synchronization.** `sync.Mutex` for short critical sections, channels for ownership transfer. One model per data structure; don't mix.

## Streaming over regex

Compile once if used: `var idPattern = regexp.MustCompile(\`id=(\w+)\`)`. Hot paths over large inputs: `bufio.Scanner` + `strings.Index`/`strings.IndexByte` instead of regex — find the prefix, slice to the delimiter, check `scanner.Err()` at the end.

## Database batching

- Bulk insert: `pool.CopyFrom(ctx, pgx.Identifier{"users"}, columns, pgx.CopyFromRows(rows))` — the fastest path.
- Multi-key read: `WHERE id = ANY($1)` with a slice parameter, not per-id queries.
- Redis: `Pipeline()` batches N commands into one round-trip.

## Testing

Standard `testing` package; table-driven tests are the idiom:

```go
func TestParseUserID(t *testing.T) {
    tests := []struct {
        name  string
        input string
        want  string
        wantErr error
    }{
        {"valid id", "user_123", "user_123", nil},
        {"empty input", "", "", ErrEmptyUserID},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := ParseUserID(tt.input)
            if !errors.Is(err, tt.wantErr) { t.Fatalf("err = %v, want %v", err, tt.wantErr) }
            if got != tt.want { t.Errorf("got %q, want %q", got, tt.want) }
        })
    }
}
```

- Integration: `testcontainers-go` for real Postgres/Redis; `httptest.NewServer` for HTTP fakes (real listener, near-zero cost).
- Time: inject a `Clock` interface (`Now() time.Time`); production wires `realClock{}`, tests a `fakeClock`. Never `time.Now()` directly in code under test.
- Coverage: `go test -race -coverprofile=coverage.out -covermode=atomic ./...` then `go tool cover -func=coverage.out`. `-race` on for any goroutine-using code — the cheapest concurrency bug detector you'll ever buy.

## Comment & godoc format

### Exported-symbol godoc

Every exported package, type, function, method, variable owes one:

```go
// FetchUser looks up a user by id.
//
// Returns the user or [ErrUserNotFound] if no row matches.
// Soft-deleted users are excluded unless includeDeleted is true.
func FetchUser(ctx context.Context, id string, includeDeleted bool) (User, error) {
```

- First sentence starts with the symbol name (the `go doc` one-liner).
- Period at the end of every sentence — godoc is sentence-aware.
- `[Symbol]` square brackets render as hyperlinks on pkg.go.dev.
- Code blocks indent one extra tab (preformatted).
- `Deprecated:` paragraph is the canonical marker; staticcheck warns on usage.
- No type info — the signature has it.

### Inline comments

Why, not what. One sentence per `//`, period when more than a clause.

- **`// nolint:rule // reason`** — bare `//nolint` is a smell; `nolintlint` enforces.
- **`// TODO(@author, YYYY-MM-DD): description`** — bare TODO rots.
- **No commented-out code in committed files.**

## Tooling — gofmt / golangci-lint / govulncheck

- **`gofmt` / `goimports`** — non-negotiable; CI fails on unformatted code.
- **`golangci-lint`** — Go's Ruff. `.golangci.yml` enable:

  ```yaml
  linters:
    enable:
      - errcheck       # unchecked errors
      - govet
      - staticcheck    # the deep one; catches most real bugs
      - unused
      - gocritic       # opinionated style + correctness
      - gosec          # security
      - revive         # naming/style (replaces golint)
      - nolintlint     # require reasons on nolint
      - ineffassign
      - misspell
      - gocyclo
      - bodyclose      # forgotten resp.Body.Close
      - sqlclosecheck  # forgotten rows.Close
      - contextcheck   # context not propagated
      - errorlint      # errors.Is / errors.As misuse
  ```

  Effective Go + Google Go Style Guide are the underlying ruleset — PEP 8's role for Go.

- **`govulncheck ./...`** in CI — checks whether your code actually reaches the vulnerable function; low false-positive rate.

`scripts/lint.sh` runs gofmt check, goimports check, golangci-lint; non-zero on any failure.
