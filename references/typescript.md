# TypeScript idioms

Language-specific guidance for `SKILL.md`. Open when writing TypeScript / JavaScript / TSX. Biased toward **server-side Node** (Fastify, Express, queue workers, CLIs); browser/React deltas at the end.

## Project layout

```
project/
├── package.json
├── tsconfig.json           # strict: true
├── src/
│   ├── index.ts            # composition root: load config, wire deps, start server
│   ├── config/             # env loading + named constants
│   ├── domain/             # pure domain logic, no I/O, no SQL
│   ├── adapters/           # one folder per external dependency (postgres/, redis/, http/)
│   └── handlers/           # HTTP routes, queue consumers, CLI subcommands
└── test/{unit,integration}/
```

- `domain/` imports only from `domain/` and `config/` — an eslint import-restriction rule catches drift.
- **No default exports** — they rename silently across files and break refactors. Named exports everywhere.

## Type system idioms

`tsc --strict` is non-negotiable.

### Banned without justification

- `any` — except type-level workarounds with an inline reason. `@typescript-eslint/no-explicit-any` is on.
- `as` cast — except at trust boundaries (`as unknown as T` after schema validation). Most `as` is a bug hiding from the compiler.
- `Function` and `Object` types — too wide; use a specific signature.
- Non-null `!` — except immediately after a narrowing the compiler can't see. Prefer `if (x === undefined) throw ...`.

### Prefer

- `unknown` over `any` — forces narrowing before use.
- **Discriminated unions** for state machines and result types; `switch (result.kind)` + compiler exhaustiveness:

  ```ts
  type FetchResult =
    | { kind: "ok"; data: User }
    | { kind: "not_found" }
    | { kind: "transient_error"; cause: Error };
  ```

- `type` for unions/aliases, `interface` for extensible object shapes — pick by intent.
- `readonly` on parameters/properties that shouldn't mutate — the type error catches the bug at the keystroke.
- `as const` for literal narrowing: `const HTTP_METHODS = ["GET","POST","PUT","DELETE"] as const; type HttpMethod = typeof HTTP_METHODS[number];`

### Interfaces at the consumer

Same rule as Python `Protocol` / Go interfaces — the consumer owns the contract; the adapter implements structurally (no `implements` needed); `index.ts` wires them.

```ts
// src/domain/user-service.ts
export interface UserRepository {
  get(userId: string): Promise<User | null>;
  save(user: User): Promise<void>;
}
```

## Errors

### Always throw `Error` (or subclass), never strings/objects

`throw "user not found"` makes the catch-site value a string and loses the stack trace.

### Small domain hierarchy

```ts
export class UserServiceError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;   // err.name survives JSON-serialized logs
  }
}
export class UserNotFoundError extends UserServiceError {}
export class UserAlreadyExistsError extends UserServiceError {}
```

`cause` (ES2022 `Error` option) carries the original — don't stuff it into a custom field.

### Wrap library errors at the adapter boundary

```ts
try {
  await this.pool.query(INSERT_USER_SQL, [user.id, user.email]);
} catch (err: unknown) {
  if (err instanceof DatabaseError && err.code === "23505") {  // unique_violation
    throw new UserAlreadyExistsError(`duplicate user id: ${user.id}`, { cause: err });
  }
  throw err;
}
```

- **`catch (err: unknown)`** (TS 4.4+ default) — the older `any` made catch blocks a type hole.
- **Narrow with `instanceof` before reading properties.**

### Result type for expected failures

Throw for genuinely exceptional conditions. For expected failures the caller branches on, prefer a Result:

```ts
type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };
```

Forces handling both arms; costs verbosity. Use where branching on the error is the norm.

### `try` / `catch` / `finally` — not `try` / `finally`

Same trap as Python and Go's bare `defer`: cleanup runs, failure invisible — raw library error to the caller, logs missing `errorName` / `cause` / correlation ids. Add the catch that observes, maps to a domain error, then propagates; cleanup stays in `finally`.

- **`try {} finally {}` alone is a smell** — "I want cleanup but don't care about the failure" is almost never true. The pattern fits only when the caller genuinely logs and re-throws, and even there an explicit `catch` makes the intent visible.
- **Fallible `finally` cleanup**: wrap each fallible call in its own nested try/catch and log. A throwing `finally` masks the primary exception.
- **`AbortSignal` cleanup belongs in `finally`** — abort the controller regardless of outcome; leaked controllers leak the underlying fetch/timer.
- **`using` declarations (TS 5.2+) replace try/finally for disposables:** `using lock = await acquireLock(user.id);` — `[Symbol.dispose]()` runs on scope exit, success or throw. Prefer when a `Disposable` exists.

## Validation at boundaries — Zod (or valibot / arktype)

TypeScript's Pydantic. `tsc` checks edit time; Zod checks runtime payloads. Untrusted inputs (HTTP body, queue message, webhook, LLM tool args, `JSON.parse` of anything) get a schema at the edge.

```ts
export const CreateUserRequest = z.object({
  email: z.string().email(),
  displayName: z.string().min(1).max(80),
  age: z.number().int().gte(13).lte(130),
  referralCode: z.string().regex(/^[A-Z0-9]{6,12}$/).optional(),
}).strict();   // rejects unknown keys — Pydantic's extra="forbid"

export type CreateUserRequest = z.infer<typeof CreateUserRequest>;
```

Discipline:

- **Parse, don't validate.** Once you hold a `CreateUserRequest`, stop re-checking shape.
- **Narrow types in the schema:** `.email()`, `.url()`, `.uuid()`, `z.coerce.date()`, `.ip()`. A bare `z.string()` for a URL is half the job.
- **`.strict()` on inbound surfaces** — silent caller-typo → loud 400.
- **`z.discriminatedUnion("type", [...])`** for tagged unions; narrows perfectly in `switch`.
- **`.refine(...)` for cross-field rules** — don't smear across the handler.
- **Cache the schema at module scope** — defined inside a handler it re-compiles per request, flamegraph-visible.
- **`safeParse` over `parse` at the boundary** — returns a discriminated union you handle explicitly.
- **Output schemas too:** `Response.parse(unknownExternalReply)` turns a `fetch()` into a typed call.
- `valibot` / `arktype`: smaller bundle, similar API. One per repo.

## Configuration — env validation via Zod (or `envalid` / `t3-env`)

pydantic-settings parallel. Validate `process.env` once at startup; never read it outside the config module.

```ts
const ConfigSchema = z.object({
  CLAW_DATABASE_URL: z.string().url(),                     // required — fail boot
  CLAW_REDIS_URL: z.string().url(),
  CLAW_API_KEY: z.string().min(20),                        // secret — never log
  CLAW_HTTP_TIMEOUT_MS: z.coerce.number().int().positive().default(5_000),
  CLAW_DB_POOL_MAX: z.coerce.number().int().gte(1).lte(200).default(20),
  CLAW_MAX_RETRY_ATTEMPTS: z.coerce.number().int().gte(1).lte(10).default(3),
  CLAW_LOG_LEVEL: z.enum(["debug", "info", "warn", "error"]).default("info"),
  CLAW_ENVIRONMENT: z.enum(["dev", "staging", "prod"]),
}).strict();

let cached: Config | undefined;
export function loadConfig(): Config {
  if (cached) return cached;
  const parsed = ConfigSchema.safeParse(process.env);
  if (!parsed.success) throw new Error(`invalid config: ${parsed.error.message}`);  // fail fast
  cached = Object.freeze(parsed.data);
  return cached;
}
```

Discipline:

- **One `ConfigSchema` per process**; sub-services `.extend({...})`.
- **Service prefix (`CLAW_`)** — otherwise sibling env vars leak in.
- **`.strict()`** — a `CLAW_DATABASE_URLL` typo fails boot loudly instead of silently defaulting.
- **`z.coerce.number()`** — `process.env` is `string | undefined`; without coercion arithmetic silently concatenates.
- **`Object.freeze`** the cached config; **module-level cache** (per-call loading burns request-path CPU).
- **No `process.env` outside this module** — positive form of the SKILL.md fingerprint.
- Richer needs: `envalid` (pre-built `port()`, `host()`, `bool()` validators); `@t3-oss/env-core` (client/server var split — leaking server env into a Next.js bundle is a security bug).
- Non-env constants stay as `UPPER_SNAKE` `const` exports — don't double-declare on the schema.

## Connection pools

Instantiate once at startup and inject. Never `new Pool()` per request.

```ts
// Postgres (pg) — statement_timeout is a session setting so the SERVER
// kills runaway queries; pg has no per-query timeout of its own.
export const pgPool = new Pool({
  connectionString: config.DATABASE_URL,
  max: 20, idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 2_000, statement_timeout: 5_000,
});

// HTTP — undici Agent (the engine under fetch). Phase timeouts on the
// Agent as backstop; AbortSignal.timeout for total wall-clock per call.
export const httpAgent = new Agent({
  connect: { timeout: 2_000 }, bodyTimeout: 5_000, headersTimeout: 5_000,
  pipelining: 1, connections: 50,   // per-origin
});
const { statusCode, body } = await request(url, {
  dispatcher: httpAgent, signal: AbortSignal.timeout(10_000),
});

// Redis (ioredis) — commandTimeout is critical: without it a stuck
// connection holds a promise forever. lazyConnect supports the
// "no startup health checks" rule.
export const redisClient = new Redis(config.REDIS_URL, {
  maxRetriesPerRequest: 3, enableReadyCheck: true, lazyConnect: true,
  connectTimeout: 2_000, commandTimeout: 500,
});
```

Avoid `axios` in new code — `fetch` / `undici.request` covers every real use case with no third-party dep and proper streaming.

## Memory and allocation

- **Stream large bodies.** `response.body` is a `ReadableStream` — pipe to a parser; don't `await response.text()` for 100 MB.
- **Avoid spread on large arrays.** `[...a, ...b]` allocates; hot paths use `a.push(...b)` or `Array.from` with capacity.
- **Reuse buffers.** Accumulate `Buffer[]`, `Buffer.concat(parts, totalLength)` — pass the total to avoid a second scan.
- **`Map` over `Object`** for high-cardinality dynamic keys — V8 shape transitions slow every access on objects; `Map` is built for it.
- **Bounded caches.** `lru-cache` with `max:` over a bare `Map` for anything risking unbounded growth.
- **Don't close over large objects.** A handler capturing `req` in a long-lived promise pins the whole request graph. Extract fields before awaiting.
- **`WeakRef` / `WeakMap`** for identity-keyed caches that shouldn't block GC.

### V8 hidden classes and monomorphism

V8's JIT relies on objects sharing a hidden class ("shape"). Monomorphic code is fast; many shapes degrade to the slow generic path. On hot paths:

- **Initialise all fields in the constructor, same order, same types** — even as `null`. A conditionally-added field creates a divergent shape:

  ```ts
  // GOOD — tag is always present; null is a shape member, not a missing field.
  class Event {
    constructor(public id: string, public ts: number, public tag: string | null = null) {}
  }
  ```

- **Never `delete obj.field`** on hot-path objects — deopts to dictionary mode permanently. Assign `null`/`undefined` or drop the reference.
- **Avoid heterogeneous arrays** — `[1, "two", {}]` triggers slow elements kind; `[1, 2, 3]` stays fast SMI.
- **Don't mutate prototype chains at runtime** (`Object.setPrototypeOf`, patching `prototype.method` after instances exist) — every instance goes mega-morphic.

### Heap sizing and GC tuning

V8's default heap limit (1.4 GB on Node ≤16, 4 GB recent) is much smaller than typical container memory. Two failure modes: `heap out of memory` long before the container OOMs (limit too low — set `--max-old-space-size=<MB>` to ~75% of container memory); GC pauses swamping p99 (raise `--max-semi-space-size=<MB>`, default 16 MB, on allocation-heavy workloads to reduce Scavenge frequency).

```bash
NODE_OPTIONS="--max-old-space-size=3072 --max-semi-space-size=64" node ./main.js
```

`--expose-gc` + manual `gc()` in production is a footgun (full stop-the-world) — benchmarks only. Profile with `--inspect` + DevTools Memory tab or `clinic heapprofiler`; don't tune flags without numbers.

### Closure-retention bugs

The most common JS leak: a callback/promise/listener captures the enclosing scope and outlives the data:

```ts
// BAD — largeBuffer pinned until the timer fires (or forever if shared).
setInterval(() => metrics.gauge("buffer_bytes", largeBuffer.length), 1_000);

// GOOD — extract the primitive.
const size = largeBuffer.length;
setInterval(() => metrics.gauge("buffer_bytes", size), 1_000);
```

Same rule for promise chains, event-emitter listeners, async iterators.

## Concurrency

Node is single-threaded for JS, I/O-concurrent. The mental model is `asyncio`, not goroutines.

### Bound your fanout

```ts
// BAD — N concurrent fetches, no cap. The most common
// "production OOM after deploy" shape in Node.
const results = await Promise.all(urls.map(fetchOne));

// GOOD — bounded with p-limit (or pMap)
const limit = pLimit(8);
const results = await Promise.all(urls.map((u) => limit(() => fetchOne(u))));
```

### Always pass a signal

Every I/O call accepts an `AbortSignal`. Tie it to the request lifecycle, deadline, or parent context; `AbortSignal.any` (Node 20+) is Go's `context.WithCancel` composition:

```ts
const signal = AbortSignal.any([
  AbortSignal.timeout(REQUEST_DEADLINE_MS),
  req.raw.signal,           // client disconnect cancels too
]);
const res = await fetch(url, { signal });
for await (const chunk of res.body!) {
  signal.throwIfAborted();
  // ...
}
```

### Promise gotchas

- A floating promise (not awaited, no `.catch`) becomes an unhandled rejection. `--unhandled-rejections=strict` + `@typescript-eslint/no-floating-promises`.
- `Promise.all` rejects on the first failure; siblings keep running. `Promise.allSettled` to collect both.
- `for await ... of` over manual `(await stream.next()).value` loops.

### Workers

CPU-bound → `worker_threads`. IPC/forking → `child_process`. Don't lean on `cluster` for HTTP load — modern load balancers do it better.

## Streaming over regex

Compile once at module level (`const ID_PATTERN = /id=(\w+)/`). Hot paths over large inputs: `indexOf`-style streaming, same shape as Python's `line.find("id=")`. **Never regex HTML** — `parse5` / `node-html-parser` (small) or `cheerio` (jQuery-style); regex-against-HTML is the fastest path to a security bug. JSON of unknown shape: `JSON.parse` + Zod, not regex.

## Database batching

```ts
// Multi-row insert via unnest — one round-trip for N rows.
await pgPool.query(
  `INSERT INTO users (id, email, created_at)
   SELECT * FROM unnest($1::text[], $2::text[], $3::timestamptz[])`,
  [users.map((u) => u.id), users.map((u) => u.email), users.map((u) => u.createdAt)],
);
// Very large inserts: pg-copy-streams (Postgres COPY) — order of magnitude faster.

// Multi-key read — one round-trip for N keys (vs N per-id queries).
const rows = await pgPool.query("SELECT * FROM users WHERE id = ANY($1::text[])", [ids]);

// Redis pipelining — one round-trip for N commands. multi() only when
// you need atomicity.
const pipeline = redisClient.pipeline();
for (const key of keys) pipeline.get(key);
const results = await pipeline.exec();
```

## HTTP clients (caller side)

`fetch` is built into Node 18+. Common mistakes:

- **Not checking `response.ok`.** `fetch` throws only on network errors, never HTTP errors. `if (!response.ok) throw new HttpError(response.status, await response.text());`
- **No timeout.** `fetch` has no default — always pass `signal: AbortSignal.timeout(...)`.
- **Reading the body twice.** Bodies stream once; `.text()` then `.json()` throws. Buffer with `.text()` and parse manually if you need both.
- **Logging URLs with credentials.** Query-string tokens end up in every proxy log.

## Testing

**vitest** for new projects (Jest-compatible, faster, native ESM); patterns apply unchanged to existing Jest.

```ts
describe("UserService.get", () => {
  let repo: UserRepository;
  beforeEach(() => {
    repo = { get: vi.fn(), save: vi.fn() };   // inject a fake of the interface
  });

  it("returns user when found", async () => {
    vi.mocked(repo.get).mockResolvedValue({ id: "u1", email: "a@b.c" });
    expect(await new UserService(repo).get("u1")).toEqual({ id: "u1", email: "a@b.c" });
  });
  it("throws UserNotFoundError when missing", async () => {
    vi.mocked(repo.get).mockResolvedValue(null);
    await expect(new UserService(repo).get("u_x")).rejects.toBeInstanceOf(UserNotFoundError);
  });
});
```

- **Table-driven via `it.each`** when the shape repeats.
- **Fake timers** for `setTimeout` / `Date.now`: `vi.useFakeTimers(); vi.setSystemTime(new Date("2026-01-01")); ... vi.useRealTimers();`
- **`testcontainers-node`** for integration against real Postgres / Redis / NATS.
- **`supertest`** (or fastify `.inject`) for HTTP-level tests — exercises routing, middleware, validation.
- **Never `mockModule` deep dependencies — inject them.** A test patching `node_modules/pg` global state breaks under parallelism.

Coverage: `vitest run --coverage --coverage.reporter=text-summary`.

## Comment & TSDoc format

### TSDoc on exported symbols

```ts
/**
 * Looks up a user by id.
 *
 * @param userId - Caller-side ULID; must be exactly 26 characters.
 * @returns The user row, or `null` if not found.
 * @throws {@link UserRepositoryError} on underlying DB failures.
 */
export async function fetchUser(userId: string): Promise<User | null> {
```

- `/** ... */` doc comments — IDEs surface on hover; `api-extractor` / `typedoc` parse them.
- First line: single-sentence summary, blank line, body (PEP 257 shape).
- Standard tags: `@param`, `@returns`, `@throws`, `@example`. Don't repeat the type in `@param` — the signature has it; document *semantic* contracts ("must be a ULID").
- `{@link Symbol}` for cross-references; `@deprecated` is the canonical tag (`import/no-deprecated` flags consumers).

### Inline comments

Why, not what. One sentence per `//`.

- **`// eslint-disable-next-line <rule> -- <reason>`** — bare disable is a smell; `eslint-comments/require-description` enforces the `--` reason.
- **`// @ts-expect-error <reason>` over `// @ts-ignore`** — `expect-error` fails when the error disappears; `ignore` rots.
- **`// TODO(@author, YYYY-MM-DD): description`** — bare TODO rots.
- **No commented-out code in committed files.**

## Tooling — TypeScript / ESLint / Prettier

- **`tsc --noEmit` in CI** as the type check; build via `esbuild`/`swc`/`tsup` for speed. `tsconfig.json` essentials:

  ```jsonc
  {
    "compilerOptions": {
      "strict": true,
      "noUncheckedIndexedAccess": true,     // arr[i] is T | undefined
      "noImplicitOverride": true,
      "noFallthroughCasesInSwitch": true,
      "exactOptionalPropertyTypes": true,
      "useUnknownInCatchVariables": true,
      "isolatedModules": true,
      "skipLibCheck": true,                 // pragmatic: skip @types/* checks
      "moduleResolution": "bundler",
      "target": "ES2022"
    }
  }
  ```

- **ESLint** with `@typescript-eslint`; `recommended-type-checked` is the floor. Always-on rules:

  ```jsonc
  {
    "extends": [
      "eslint:recommended",
      "plugin:@typescript-eslint/recommended-type-checked",
      "plugin:@typescript-eslint/stylistic-type-checked",
      "plugin:import/recommended", "plugin:import/typescript",
      "prettier"
    ],
    "rules": {
      "@typescript-eslint/no-floating-promises": "error",   // catches the #1 async bug class
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/await-thenable": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/consistent-type-imports": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/switch-exhaustiveness-check": "error",
      "import/order": ["error", { "newlines-between": "always" }],
      "import/no-cycle": "error",
      "eslint-comments/require-description": ["error", { "ignore": [] }]
    }
  }
  ```

- **Prettier** (or biome) for formatting; `eslint-config-prettier` disables ESLint's stylistic rules so they don't fight.
- **npm/pnpm audit, snyk, or `osv-scanner`** in CI.

`scripts/lint.sh` covers TS: `tsc --noEmit` + `eslint --max-warnings 0` + `prettier --check`.

## Browser / React additions

### Rendering safety

- **Never `dangerouslySetInnerHTML` with user-controlled content.** If user HTML is truly required, sanitise with `DOMPurify` and document why.
- **Validate URL schemes in `href`/`src`** — `javascript:` and `data:` pass `encodeURIComponent`: `const safeHref = (url: string) => /^https?:/i.test(url) ? url : "#";`

### Effects and cleanup

- Every subscribing `useEffect` (listener, interval, fetch) returns a cleanup — forgetting leaks across re-mounts and hot-reloads.
- Pass an `AbortController` signal to in-effect `fetch`; abort in the cleanup; swallow only `AbortError`.

### State

- `useState` local; `useReducer` for non-trivial transitions; Context for cross-cutting (auth, theme). No global state library (`zustand`, `redux`) until two unrelated subtrees share state — that's the signal.
- Lift state only to the lowest common ancestor that needs it.

### Memoization

- `React.memo` / `useMemo` / `useCallback` only on a measured problem — dependency arrays add churn and comparison isn't free. The cheapest win is usually fixing an unnecessary parent re-render, not memoizing the child.

### Server components / SSR

- Guard `window` / `document` / `localStorage` for SSR (`typeof window !== "undefined"`) or move to a client component (`"use client"`).
- Don't import secrets-aware modules into client components — the bundler ships them to the browser.

### Accessibility

- Interactive elements are real `<button>` / `<a>`, never `<div onClick>`. `aria-*` is not a substitute for the right element. Form fields have a `<label>`.

### Browser perf

- Defer non-critical JS (`<script type="module" defer>`, Next `<Script strategy="lazyOnload">`).
- Avoid layout thrash — group reads (`getBoundingClientRect`) before writes (`style.height = ...`); mixing in a loop forces a relayout per pair.
- Images: `next/image` (or equivalent) with explicit dimensions to prevent CLS.
