# Go idioms

Language-specific guidance for the `SKILL.md` principles. Open this when writing
Go.

## Project layout

```
project/
├── go.mod
├── cmd/
│   └── service/
│       └── main.go         # tiny: parse config, wire dependencies, start server
├── internal/
│   ├── config/             # constants and config loading
│   ├── domain/             # pure domain logic, no I/O, no SQL
│   ├── adapters/           # one package per external dependency
│   │   ├── postgres/
│   │   ├── redis/
│   │   └── http/
│   └── handlers/           # HTTP handlers, queue consumers, CLI commands
└── pkg/                    # only if there is genuinely a library shareable outside the module
```

`internal/` is compiler-enforced (unimportable from outside the module) — use it
liberally, reach for `pkg/` only for a genuine public API. `cmd/service/main.go`
stays small: load config, instantiate concrete adapters, inject into domain,
start the server; anything more belongs deeper.

## Errors

No exceptions. The model:

```go
// Define sentinel errors at package level for known conditions.
var (
    ErrUserNotFound      = errors.New("user not found")
    ErrUserAlreadyExists = errors.New("user already exists")
)

// Wrap with %w when crossing layers, so callers can still use errors.Is/As.
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

Callers use `errors.Is(err, ErrUserAlreadyExists)` to check the condition
without depending on the wrapping string. Rules:

- Always check errors. `_ = something()` is a smell — comment why ignoring is
  correct.
- Wrap with `%w` + a description of the attempted action when crossing a layer
  boundary.
- Don't panic in library code — panic is for unrecoverable programmer errors (a
  `nil` map you wrote), not input validation.
- `defer` cleanup the moment the resource is acquired — the reader shouldn't
  scan ahead to find the close.

## Interfaces — at the consumer, not the producer

The consumer knows what it needs:

```go
// In internal/domain/user_service.go
type UserRepository interface {
    Get(ctx context.Context, userID string) (User, error)
    Save(ctx context.Context, user User) error
}

type UserService struct {
    repo UserRepository
}

func NewUserService(repo UserRepository) *UserService {
    return &UserService{repo: repo}
}
```

`PostgresUserRepository` in `internal/adapters/postgres/` satisfies it
structurally (no `implements` keyword); `main.go` wires them. Keep interfaces
small — one method is often right, ten is usually wrong. A "god interface" with
everything a struct does is a renamed struct, not an abstraction.

## Constants and configuration

Group related constants in `const` blocks:

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

Startup config goes through a struct, parsed once:

```go
type Config struct {
    DatabaseURL        string        `env:"DATABASE_URL,required"`
    RedisURL           string        `env:"REDIS_URL,required"`
    HTTPTimeoutSeconds time.Duration `env:"HTTP_TIMEOUT_SECONDS" envDefault:"5s"`
}
```

Use `caarlos0/env` or `kelseyhightower/envconfig`. Resist `os.Getenv` outside
this struct.

## Connection pools

**Postgres (pgx)** — the pool is the default, sized via `pgxpool.Config`:

```go
poolConfig, err := pgxpool.ParseConfig(cfg.DatabaseURL)
if err != nil {
    return nil, fmt.Errorf("parse db config: %w", err)
}
poolConfig.MaxConns = DefaultDBPoolMaxOpenConns
poolConfig.MinConns = DefaultDBPoolMinOpenConns
poolConfig.MaxConnLifetime = DefaultDBConnMaxLifetime

pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
```

**HTTP (`net/http`)** — one `*http.Client` per process with an explicit
`Transport`. Never `http.DefaultClient` in production — no timeout, shared state.

```go
var sharedHTTPClient = &http.Client{
    Timeout: DefaultHTTPTimeoutSeconds * time.Second,
    Transport: &http.Transport{
        MaxIdleConns:        100,
        MaxIdleConnsPerHost: 20,
        IdleConnTimeout:     90 * time.Second,
    },
}
```

**Redis (go-redis)** — the client is a pool internally; read/write timeouts are
critical (without them a stuck connection holds a goroutine forever):

```go
redisClient := redis.NewClient(&redis.Options{
    Addr:         cfg.RedisAddr,
    PoolSize:     50,
    MinIdleConns: 10,
    DialTimeout:  2 * time.Second,
    ReadTimeout:  500 * time.Millisecond,
    WriteTimeout: 500 * time.Millisecond,
})
```

## Memory and allocation

- **`sync.Pool`** for high-frequency allocate-and-discard objects (buffers,
  encoders, large structs):

  ```go
  var bufferPool = sync.Pool{
      New: func() any { return new(bytes.Buffer) },
  }

  func render(w io.Writer, data Payload) error {
      buf := bufferPool.Get().(*bytes.Buffer)
      defer func() {
          buf.Reset()
          bufferPool.Put(buf)
      }()
      // build into buf, then write out
      ...
  }
  ```

- **Pre-size slices and maps** when capacity is known: `make([]Item, 0, n)`,
  `make(map[string]Item, n)`.
- **`strings.Builder`** for string concat in loops (`s += part` allocates each
  time).
- **Avoid reflection in hot paths** — `encoding/json` reflection is fine on
  control planes; on data planes use code-generated marshalers (`easyjson`,
  `ffjson`, or hand-written).
- **Large structs by pointer** (avoid copying), **small by value** (avoid
  pointer-chasing).

## Concurrency

- **Every goroutine has a known exit.** No stop signal → a leak.
- **Pass `context.Context` first** to anything doing I/O or that might block.
  Cancel on shutdown, request abort, deadline.
- **`errgroup.Group`** when fanning out fallible work — it cancels siblings on
  first failure:

  ```go
  g, ctx := errgroup.WithContext(ctx)
  for _, item := range items {
      item := item
      g.Go(func() error {
          return processItem(ctx, item)
      })
  }
  if err := g.Wait(); err != nil {
      return fmt.Errorf("process items: %w", err)
  }
  ```

- **No shared state without synchronization** — `sync.Mutex` for short critical
  sections, channels for ownership transfer. One model per data structure; don't
  mix.

## Streaming over regex

Same as Python: compile once if you must use regex:

```go
var idPattern = regexp.MustCompile(`id=(\w+)`)
```

For hot paths over large inputs, prefer `bufio.Scanner` + `strings.Index`:

```go
const idPrefix = "id="

func extractIDs(r io.Reader) ([]string, error) {
    var ids []string
    scanner := bufio.NewScanner(r)
    for scanner.Scan() {
        line := scanner.Text()
        idx := strings.Index(line, idPrefix)
        if idx == -1 {
            continue
        }
        rest := line[idx+len(idPrefix):]
        end := strings.IndexByte(rest, ' ')
        if end == -1 {
            ids = append(ids, rest)
        } else {
            ids = append(ids, rest[:end])
        }
    }
    if err := scanner.Err(); err != nil {
        return nil, fmt.Errorf("extract ids: %w", err)
    }
    return ids, nil
}
```

## Database batching

`CopyFrom` is the fastest pgx bulk insert:

```go
rows := make([][]any, 0, len(users))
for _, u := range users {
    rows = append(rows, []any{u.ID, u.Email, u.CreatedAt})
}
_, err := pool.CopyFrom(
    ctx,
    pgx.Identifier{"users"},
    []string{"id", "email", "created_at"},
    pgx.CopyFromRows(rows),
)
```

Multi-key reads → `WHERE id = ANY($1)` with a slice, not per-id queries. Redis →
`Pipeline()` batches into one round-trip, same as Python.

## Testing

Standard `testing`; table-driven is the idiom:

```go
func TestParseUserID(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        want    string
        wantErr error
    }{
        {"valid id", "user_123", "user_123", nil},
        {"empty input", "", "", ErrEmptyUserID},
        {"with whitespace", "  user_123  ", "user_123", nil},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := ParseUserID(tt.input)
            if !errors.Is(err, tt.wantErr) {
                t.Fatalf("err = %v, want %v", err, tt.wantErr)
            }
            if got != tt.want {
                t.Errorf("got %q, want %q", got, tt.want)
            }
        })
    }
}
```

Integration → `testcontainers-go` for real Postgres/Redis; `httptest.NewServer`
for HTTP fakes (real listener, near-zero cost). Time-dependent code → inject a
`Clock` interface (`Now() time.Time`); prod uses `realClock{}`, tests a
`fakeClock`. Never let `time.Now()` appear directly in code under test.

```bash
go test -race -coverprofile=coverage.out -covermode=atomic ./...
go tool cover -func=coverage.out
```

`-race` on for any goroutine-using code — the cheapest concurrency bug detector
you'll ever buy.

## Tooling

- **`gofmt` / `goimports`** — non-negotiable formatting.
- **`golangci-lint`** — curated `.golangci.yml`, at minimum `errcheck`,
  `govet`, `staticcheck`, `unused`, `gocritic`, `gosec`.
- **`govulncheck`** — vulnerability scanning in CI.

`scripts/lint.sh` runs gofmt check, goimports check, and golangci-lint, exiting
non-zero on any failure.
