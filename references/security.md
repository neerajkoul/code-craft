# Security

Open this when the task touches authentication, authorization, secrets,
untrusted input, dependencies, or anything network-exposed. Security is a
design concern, not a final pass. This file gives the threat-model approach, the
dependency workflow, and a pitfall checklist.

## Threat modeling at design time

Five minutes before writing — a conscious thought, not a document. Ask, in
order:

1. **What does this code do?** Plainly.
2. **What are the inputs, and which can an attacker control?**
3. **What does it produce or modify?** Worst case if the attacker controlled
   every input?
4. **What sensitive data does it touch?** Read or write? Logged or not?
5. **What dependencies?** Network, filesystem, env, third-party packages — each
   an attack vector.

**Worked example — endpoint accepting a user-uploaded CSV, inserting rows:**

- **Input:** multipart upload, attacker-controlled.
- **Risks:** size (DoS via huge file), content (CSV injection in spreadsheets,
  SQL injection via row contents, malformed-encoding parser crash), filename
  (path traversal), MIME type (claimed-CSV-actually-binary).
- **Output:** rows in `user_upload`; worst case is arbitrary table content — SQL
  injection if templated anywhere, XSS if shown to other users.
- **Deps:** CSV parser, DB driver, multipart parser — each a CVE candidate.

That five-minute thought changes the code: max upload size, streaming CSV reader
to bound memory, row/column-count validation, parameterized inserts (always),
system-generated filename, escape on output.

## OWASP-style checklist

Not exhaustive — the set to be paranoid about by default.

### Input handling

- **Validate before use.** Schema (pydantic / Go struct + validation), reject
  non-matches. Validation = type, length, range, allowed-character set.
- **Bound everything sized.** Max upload, array length, string length, nesting
  depth. Unbounded input is a DoS waiting.
- **Distrust filenames.** Never use an uploaded filename as a path. Generate a
  system identifier; store the original separately and escape on display.
- **Distrust MIME / Content-Type.** Claims, not facts. Sniff the content if you
  need the type.

### Injection

- **Parameterized queries always.** No string concatenation into SQL, ever —
  the driver escapes; don't reimplement it.
- **Same for shell / LDAP / XPath / NoSQL.** Interpolating user input into a
  command-shaped string is wrong.
- **Same for HTML / XML / JSON output.** Escape by default via a templating
  library. Never `f"<div>{user_input}</div>"`.

### Secrets

- **Never in code, logs, or error messages.** Env vars at startup, or a secrets
  manager on demand.
- **Never in URLs** — logged in proxies, browser history, CDN logs. A token in a
  query param is a token in a hundred logs you don't own.
- **Never in version control.** Pre-commit hooks (`gitleaks`, `detect-secrets`)
  for the obvious, review for the subtle.
- **Rotate.** A secret you can't rotate is one that will eventually leak.

### Authn / authz

- **Authenticate before authorizing.** "Who is this?" before "what may they
  do?" Confusing them is how privilege escalation happens.
- **Authorize on every request**, not the first only. Authorize-once-then-trust
  escalates trivially.
- **Default deny.** New endpoints/resources/actions start at no access until
  explicitly granted.
- **Constant-time token compare.** `secrets.compare_digest` (Py),
  `subtle.ConstantTimeCompare` (Go). `==` leaks timing.

### Logging

- **Enough to debug, not enough to leak.** IDs, request IDs, error types — yes.
  Passwords, tokens, full request/response bodies — no.
- **Structured (JSON)** so downstream tools parse it; free text drifts
  un-grep-able.
- **Wary of logging exceptions verbatim** — some include the offending input,
  and if that held a secret it's now in the logs.

### Network

- **TLS everywhere, including internal.** "Inside the VPC" isn't a reason to
  skip it — the cluster has guests, the network has snoopers.
- **Verify certificates.** No `verify=False` (httpx/requests), no
  `InsecureSkipVerify: true` (Go). Legitimately need to skip (self-signed dev)
  → gate behind a flag and shout about it.
- **Pin certificates** for high-stakes upstreams when feasible — defends against
  compromised CAs.

### Concurrency

- **Race conditions are security bugs.** Check-then-act on a shared resource
  without locking is a TOCTOU vuln. Wrap state-changing ops in transactions or
  locks.
- **Idempotency for retries.** A duplicate retry must not produce a duplicate
  side effect — use idempotency keys for writes.

## Dependency hygiene

Dependencies are the largest attack surface — most modern exploits hit a
transitive dependency you've never heard of, not your code.

**Pin versions.** Python: exact versions in `requirements.txt`, or a committed
`poetry.lock` / `uv.lock` / `pdm.lock` — never `>=` for production. Go: `go.sum`
is automatic and committed; pin minor versions in `go.mod`, `go mod tidy` keeps
it honest.

**Scan in CI** on every push to main and every PR; fail the build above a
severity threshold (high/critical), file issues below.

```bash
pip-audit --strict      # Python — PyPA, queries OSV
govulncheck ./...       # Go — checks reachability, not just imported version
```

**Review what gets pulled in.** Before a new direct dep: check the transitive
footprint (`pip install --dry-run`, `go mod why`); check maintenance state (last
commit, open issues, maintainer count — a single unmaintained maintainer is a
supply-chain risk); consider whether 30 lines beats a 30 MB transitive
dependency.

**Update on a schedule.** Renovate/Dependabot file PRs; triage weekly.
Security-flagged merge immediately, routine minor bumps batch.

## When you find a vulnerability

**Your own code:** confirm the exploit path is reachable in prod and what
triggers it → patch in private (don't telegraph the bug in a public commit) →
deploy → rotate credentials if anything could've been exposed → post-mortem the
process gap.

**A dependency:** upgrade to a fixed version (test, deploy); if none exists,
mitigate at your layer (input validation, capability removal, feature flag) and
document it; track upstream and remove the mitigation when a fix lands.

## Checklist before "ready"

- [ ] All inputs validated and bounded.
- [ ] All SQL/shell/LDAP/etc. parameterized.
- [ ] No secrets in code, logs, URLs, error messages, or version control.
- [ ] Authn checked every request; authz re-checked on every authorized action.
- [ ] All HTML/JSON/XML output escaped by the templating library.
- [ ] All crypto comparisons constant-time.
- [ ] TLS on every network call; certificates verified.
- [ ] Dependency scanner passes — no high/critical findings.
- [ ] Secret-detection pre-commit hook installed.
