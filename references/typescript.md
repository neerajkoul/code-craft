# TypeScript idioms

Language-specific guidance for the `SKILL.md` principles. Open this when writing
TypeScript; cross-reference `python.md` / `golang.md` only if a decision spans
languages.

Biased toward **server-side Node** (Fastify, Express, queue workers, CLIs); a
"Browser / React additions" section at the end covers front-end deltas.

## Project layout

```
project/
├── package.json
├── tsconfig.json           # strict: true, no implicit any
├── src/
│   ├── index.ts            # tiny: load config, wire deps, start server
│   ├── config/             # env loading + named constants
│   ├── domain/             # pure domain logic, no I/O, no SQL
│   ├── adapters/           # one folder per external dependency
│   │   ├── postgres/
│   │   ├── redis/
│   │   └── http/
│   └── handlers/           # HTTP routes, queue consumers, CLI subcommands
└── test/
    ├── unit/
    └── integration/
```

- `src/index.ts` is the composition root — load config, instantiate adapters,
  inject into domain, start the server; nothing more.
- `domain/` imports only from `domain/` and `config/`. An eslint
  import-restriction rule catches drift.
- **No default exports** — they rename silently across files and break
  refactors. Named exports everywhere.

## Type system idioms

Run `tsc --strict` (`noImplicitAny`, `strictNullChecks`, `strictFunctionTypes`,
…). Non-negotiable.

**Banned without justification:**

- `any` — except type-level workarounds with an inline why-comment
  (`@typescript-eslint/no-explicit-any` on).
- `as` cast — except at trust boundaries (`as unknown as T` after schema
  validation). Most `as` uses are bugs hiding from the compiler.
- `Function` / `Object` types — too wide; use a specific signature.
- Non-null `!` — except right after narrowing the compiler can't see; prefer
  `if (x === undefined) throw ...`.

**Prefer:**

- `unknown` over `any` when the type isn't yet known — forces a narrowing.
- Discriminated unions for state machines and result types:

  ```ts
  type FetchResult =
    | { kind: "ok"; data: User }
    | { kind: "not_found" }
    | { kind: "transient_error"; cause: Error };
  ```

  The caller `switch (result.kind)` and the compiler exhaustiveness-checks.
- `type` for unions/aliases, `interface` for extensible object shapes — both
  compile away, pick by intent.
- `readonly` on params/properties that shouldn't mutate — caught at the
  keystroke.
- `as const` for literal-narrowing constants:

  ```ts
  const HTTP_METHODS = ["GET", "POST", "PUT", "DELETE"] as const;
  type HttpMethod = typeof HTTP_METHODS[number];
  // HttpMethod = "GET" | "POST" | "PUT" | "DELETE"
  ```

**Interfaces at the consumer** — same rule as Python `Protocol` and Go
interfaces:

```ts
// src/domain/user-service.ts
export interface UserRepository {
  get(userId: string): Promise<User | null>;
  save(user: User): Promise<void>;
}

export class UserService {
  constructor(private readonly repo: UserRepository) {}
  // ...
}
```

The Postgres impl in `src/adapters/postgres/user-repository.ts` implements it
structurally (no `implements` needed); `index.ts` wires them.

## Errors

JS inherited `throw` from Java with neither typed nor checked exceptions.
Conventions to compensate:

**Always throw `Error` (or a subclass), never strings/objects** — the stack
trace lives on `Error`:

```ts
// BAD — `throw "user not found"` makes `err` a string at the catch site
throw "user not found";

// GOOD
throw new UserNotFoundError(userId);
```

**Define a small hierarchy:**

```ts
export class UserServiceError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class UserNotFoundError extends UserServiceError {}
export class UserAlreadyExistsError extends UserServiceError {}
```

`name = new.target.name` makes `err.name === "UserNotFoundError"` so JSON logs
preserve the type. `cause` (ES2022 `Error` constructor) replaces stuffing the
original into a custom field.

**Wrap library errors at the adapter boundary:**

```ts
async save(user: User): Promise<void> {
  try {
    await this.pool.query(INSERT_USER_SQL, [user.id, user.email]);
  } catch (err: unknown) {
    if (err instanceof DatabaseError && err.code === "23505") {  // unique_violation
      throw new UserAlreadyExistsError(
        `duplicate user id: ${user.id}`,
        { cause: err },
      );
    }
    throw err;
  }
}
```

`catch (err: unknown)` (TS 4.4+ default; the old `any` was a type hole) and
type-narrow with `instanceof` before reading properties — `err.code` on an
unknown is a compile error.

**Result type for expected failures** the caller branches on (e.g. "not found"
in a search flow) — throwing stays for genuinely exceptional conditions:

```ts
type Result<T, E = Error> =
  | { ok: true; value: T }
  | { ok: false; error: E };

async function findUser(id: string): Promise<Result<User, UserNotFoundError>> {
  const user = await repo.get(id);
  return user
    ? { ok: true, value: user }
    : { ok: false, error: new UserNotFoundError(id) };
}
```

Forces the caller to handle both arms; cost is more verbose call sites. Use
where branching on the error is the norm.

## Constants and configuration

Module constants in `UPPER_SNAKE`. Validate config at startup through one
schema; never read `process.env` outside `config/`:

```ts
// src/config/index.ts
import { z } from "zod";

export const DEFAULT_HTTP_TIMEOUT_MS = 5_000;
export const DEFAULT_MAX_RETRY_ATTEMPTS = 3;
export const DEFAULT_CIRCUIT_BREAKER_OPEN_DURATION_MS = 30_000;

const ConfigSchema = z.object({
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url(),
  HTTP_TIMEOUT_MS: z.coerce.number().int().positive()
    .default(DEFAULT_HTTP_TIMEOUT_MS),
  LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
});

export type Config = z.infer<typeof ConfigSchema>;

export function loadConfig(): Config {
  const parsed = ConfigSchema.safeParse(process.env);
  if (!parsed.success) {
    // Fail fast at startup — never run with an invalid config.
    throw new Error(`invalid config: ${parsed.error.message}`);
  }
  return parsed.data;
}
```

Zod (or `valibot` / `arktype`) at the boundary buys runtime validation *and* the
inferred TS type. `process.env` is always `string | undefined` — don't trust it
to match your type.

## Connection pools

Instantiate once at startup and inject; never `new Pool()` per request.

**Postgres (`pg` or `postgres.js`):**

```ts
import { Pool } from "pg";

export const DEFAULT_DB_POOL_MAX = 20;
export const DEFAULT_DB_POOL_IDLE_TIMEOUT_MS = 30_000;
export const DEFAULT_DB_CONN_TIMEOUT_MS = 2_000;
export const DEFAULT_DB_STATEMENT_TIMEOUT_MS = 5_000;

export const pgPool = new Pool({
  connectionString: config.DATABASE_URL,
  max: DEFAULT_DB_POOL_MAX,
  idleTimeoutMillis: DEFAULT_DB_POOL_IDLE_TIMEOUT_MS,
  connectionTimeoutMillis: DEFAULT_DB_CONN_TIMEOUT_MS,
  statement_timeout: DEFAULT_DB_STATEMENT_TIMEOUT_MS,
});
```

`pg` has no per-query timeout of its own — `statement_timeout` is sent to
Postgres as a session setting so the server kills runaway queries.

**HTTP** — `undici` (Node's built-in client, under `fetch`); a shared `Agent`
manages the pool:

```ts
import { Agent, request } from "undici";

export const httpAgent = new Agent({
  connect: { timeout: DEFAULT_HTTP_CONNECT_TIMEOUT_MS },
  bodyTimeout: DEFAULT_HTTP_READ_TIMEOUT_MS,
  headersTimeout: DEFAULT_HTTP_READ_TIMEOUT_MS,
  pipelining: 1,
  connections: 50,    // per-origin
});

const { statusCode, body } = await request(url, {
  dispatcher: httpAgent,
  signal: AbortSignal.timeout(DEFAULT_HTTP_TOTAL_TIMEOUT_MS),
});
```

`AbortSignal.timeout` caps total wall-clock; the Agent timeouts cap individual
phases (connect, headers, body). Use both. Avoid `axios` in new code — `fetch` /
`undici.request` covers every real use case with no third-party dep and proper
streaming.

**Redis (`ioredis`):**

```ts
import Redis from "ioredis";

export const redisClient = new Redis(config.REDIS_URL, {
  maxRetriesPerRequest: 3,
  enableReadyCheck: true,
  lazyConnect: true,
  connectTimeout: 2_000,
  commandTimeout: 500,
});
```

`commandTimeout` is critical (a stuck connection holds a promise forever);
`lazyConnect` defers connection to the first command, supporting "no startup
health checks."

## Memory and allocation

V8 is more forgiving than CPython but rewards the same discipline:

- **Stream large bodies.** `response.body` is a `ReadableStream` — pipe to a
  parser; don't `await response.text()` on a 100 MB response.
- **Avoid `array.spread` on large arrays.** `[...a, ...b]` allocates; hot paths
  → `a.push(...b)` (in-place) or `Array.from(iter)` with a capacity hint.
- **Reuse buffers.** Accumulate `Buffer[]` and `Buffer.concat(parts,
  totalLength)` at the end (pass the total length to avoid a second scan).
- **`Map` over `Object`** for high-cardinality dynamic keys — V8 transitions
  object shapes as keys grow, slowing every access.
- **Bounded caches.** `lru-cache` (set `max:`) over `new Map()` for
  request-scoped caches that risk unbounded growth.
- **Avoid closing over large objects.** A handler capturing `req` in a
  long-lived promise pins the whole request graph — extract the fields you need
  before awaiting.
- **WeakRef / WeakMap** for identity-keyed caches that shouldn't prevent GC.

## Concurrency

Node is single-threaded for JS but I/O-concurrent — the mental model is Python
`asyncio`, not Go goroutines.

**Bound your fanout:**

```ts
// BAD — N concurrent fetches, no cap
const results = await Promise.all(urls.map(fetchOne));

// GOOD — bounded with p-limit (or pMap)
import pLimit from "p-limit";
const limit = pLimit(8);
const results = await Promise.all(
  urls.map((u) => limit(() => fetchOne(u))),
);
```

Unbounded `Promise.all` is the most common "production OOM after deploy" shape
in Node.

**Always pass a signal** tied to request lifecycle / deadline / parent context:

```ts
async function handleRequest(req: FastifyRequest): Promise<Response> {
  const signal = AbortSignal.any([
    AbortSignal.timeout(REQUEST_DEADLINE_MS),
    req.raw.signal,  // client disconnect cancels too
  ]);
  return doWork(signal);
}

async function doWork(signal: AbortSignal): Promise<Response> {
  const res = await fetch(url, { signal });
  // signal also pipes through to your own async work:
  for await (const chunk of res.body!) {
    signal.throwIfAborted();
    // ...
  }
}
```

`AbortSignal.any` (Node 20+) is the equivalent of Go's `context.WithCancel`
composition.

**Promise gotchas:**

- A floating promise (returned, not awaited, no `.catch`) becomes an unhandled
  rejection. Enable `--unhandled-rejections=strict` and
  `@typescript-eslint/no-floating-promises`.
- `Promise.all` rejects on first failure; siblings keep running. Use
  `Promise.allSettled` to collect both.
- `for await ... of` over `(await stream.next()).value` loops — shorter and
  safer.

**Workers:** `worker_threads` for CPU-bound; `child_process` for IPC/forking.
Don't use `cluster` for HTTP load — modern load balancers do it better.

## Streaming over regex

Same as Python/Go — compile once if used:

```ts
const ID_PATTERN = /id=(\w+)/;   // module-level; compiled once

function* extractIds(lines: Iterable<string>): Iterable<string> {
  for (const line of lines) {
    const match = ID_PATTERN.exec(line);
    if (match) yield match[1];
  }
}
```

Hot paths / large inputs → `indexOf`-style streaming (same shape as Python's
`line.find("id=")`). **Never regex HTML** — use `parse5` / `node-html-parser`
(small) or `cheerio`; regex against HTML is the fastest path to a security bug.
JSON of unknown shape → `JSON.parse` + Zod, not regex.

## Database batching

**`pg` — multi-row insert via `unnest`** (one round-trip for N rows; very large
→ `pg-copy-streams` / `COPY`, an order of magnitude faster):

```ts
await pgPool.query(
  `INSERT INTO users (id, email, created_at)
   SELECT * FROM unnest($1::text[], $2::text[], $3::timestamptz[])`,
  [
    users.map((u) => u.id),
    users.map((u) => u.email),
    users.map((u) => u.createdAt),
  ],
);
```

**`pg` — multi-key read** (one round-trip for N keys vs N for the naive
per-id loop):

```ts
const rows = await pgPool.query(
  "SELECT * FROM users WHERE id = ANY($1::text[])",
  [ids],
);
```

**Redis pipelining** (one round-trip for N commands; `multi()` adds
transactional semantics — use only when you need atomicity):

```ts
const pipeline = redisClient.pipeline();
for (const key of keys) pipeline.get(key);
const results = await pipeline.exec();
```

## HTTP clients (caller side)

`fetch` is built into Node 18+ — prefer it for new code:

```ts
const response = await fetch(url, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(payload),
  signal: AbortSignal.timeout(DEFAULT_HTTP_TOTAL_TIMEOUT_MS),
});

if (!response.ok) {
  // 4xx and 5xx do NOT throw — you must check ok / status yourself.
  throw new HttpError(response.status, await response.text());
}

const body = await response.json();
```

Common mistakes: not checking `response.ok` (`fetch` throws only on network
errors, not HTTP errors — axios hid this, but the underlying API is what modern
Node uses); forgetting the timeout (`fetch` has none — always pass a signal);
reading the body twice (`.text()` then `.json()` throws — bodies stream once;
buffer with `.text()` and parse manually if you need both); logging URLs with
credentials (query-string tokens end up in every proxy log).

## Testing

**vitest** for new projects (Jest-compatible API, faster, native ESM); the
patterns apply unchanged to existing Jest setups.

```ts
// src/domain/user-service.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { UserService } from "./user-service.js";
import type { UserRepository } from "./user-service.js";

describe("UserService.get", () => {
  let repo: UserRepository;
  let service: UserService;

  beforeEach(() => {
    repo = {
      get: vi.fn(),
      save: vi.fn(),
    };
    service = new UserService(repo);
  });

  it("returns user when found", async () => {
    vi.mocked(repo.get).mockResolvedValue({ id: "u1", email: "a@b.c" });
    expect(await service.get("u1")).toEqual({ id: "u1", email: "a@b.c" });
  });

  it("throws UserNotFoundError when missing", async () => {
    vi.mocked(repo.get).mockResolvedValue(null);
    await expect(service.get("u_missing")).rejects.toBeInstanceOf(
      UserNotFoundError,
    );
  });

  it("wraps repository error in service error", async () => {
    vi.mocked(repo.get).mockRejectedValue(new Error("connection refused"));
    await expect(service.get("u1")).rejects.toBeInstanceOf(UserServiceError);
  });
});
```

- **Table-driven with `it.each`** when the shape repeats:

  ```ts
  it.each([
    ["", false],
    ["a", true],
    ["a@b", false],
    ["a@b.c", true],
  ])("isValidEmail(%s) === %s", (input, expected) => {
    expect(isValidEmail(input)).toBe(expected);
  });
  ```

- **Fake timers** for `setTimeout` / `Date.now`:

  ```ts
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-01-01"));
  // ... assert ...
  vi.useRealTimers();
  ```

- **`testcontainers-node`** for integration vs real Postgres/Redis/NATS.
- **`supertest`** (or fastify `.inject`) for HTTP-level tests — exercises
  routing, middleware, validation.
- **Never `mockModule` deep dependencies** — inject them. Patching
  `node_modules/pg` global state breaks under parallelism.

```bash
vitest run --coverage --coverage.reporter=text-summary
```

## Tooling

- **TypeScript** strict mode; `tsc --noEmit` is the CI type check, the build can
  use `esbuild` / `swc` / `tsup` for speed.
- **eslint + `@typescript-eslint`** `recommended-type-checked` preset; add the
  import-order and no-floating-promises rules.
- **Prettier** (run by the lint step) — or **biome** for one tool doing lint +
  format.
- **npm/pnpm audit / snyk** for dependency scanning in CI.

`scripts/lint.sh` covers TS alongside Python and Go — `tsc --noEmit` + `eslint`
+ `prettier --check`.

## Browser / React additions

Most of the above applies; the deltas worth calling out:

**React rendering safety.** Never `dangerouslySetInnerHTML` with user content;
if you truly need user-supplied HTML, sanitise with `DOMPurify` first and
document why HTML was required. URLs in `href`/`src` — validate the scheme
(`javascript:` and `data:` are the SSRF-adjacent risk):

```ts
const safeHref = (url: string) =>
  /^https?:/i.test(url) ? url : "#";
```

**Effects and cleanup.** Every subscribing `useEffect` (listener, interval,
fetch) returns a cleanup — forgetting it leaks across re-mounts and hot-reloads.
Pass an `AbortController` signal to in-effect `fetch`, abort in cleanup:

```ts
useEffect(() => {
  const controller = new AbortController();
  fetch(url, { signal: controller.signal })
    .then((r) => r.json())
    .then(setData)
    .catch((err) => {
      if (err.name !== "AbortError") setError(err);
    });
  return () => controller.abort();
}, [url]);
```

**State.** `useState` for local, `useReducer` for non-trivial transitions,
Context for cross-cutting (auth, theme). Don't reach for `zustand`/`redux` until
two unrelated subtrees share state — that's the signal. Lift state only to the
lowest common ancestor that needs it.

**Memoization.** `React.memo` / `useMemo` / `useCallback` only on a measured
problem — premature memoization is its own perf bug (dependency arrays add churn,
the comparison isn't free). The cheapest win is usually fixing an unnecessary
parent re-render, not memoizing the child.

**Server components / SSR.** Code using `window` / `document` / `localStorage`
must be SSR-guarded (`typeof window !== "undefined"`) or in a client component
(`"use client"`). Don't import secrets-aware modules into client components — the
bundler ships them to the browser.

**Accessibility.** Interactive elements are real `<button>` / `<a>`, not
`<div onClick>` (screen readers and keyboard users depend on it); `aria-*` is no
substitute for the right element; form fields have an associated `<label>`.

**Browser perf.** Defer non-critical JS (`<script type="module" defer>` /
Next.js `<Script strategy="lazyOnload">`). Avoid layout thrash — group reads
(`getBoundingClientRect`) before writes (`style.height = ...`); mixing them in a
loop forces a relayout per pair. Images: `next/image` (or equivalent) with
explicit dimensions to reserve space and prevent CLS.
