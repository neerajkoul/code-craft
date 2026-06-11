# Security

Open when the task touches authentication, authorization, secrets, untrusted input, dependencies, or anything network-exposed. Security is a design concern, not a final pass.

## Threat modeling at design time

Five minutes of conscious thought before code. Ask, in order:

1. **What does this code do?** State plainly.
2. **What are the inputs?** Where from? Which can an attacker control?
3. **What does it produce or modify?** Worst case if an attacker controls the inputs?
4. **What sensitive data does it touch?** Read/write? Logged?
5. **What dependencies?** Network, filesystem, environment, packages — each an attack vector.

Worked example — endpoint accepting a user-uploaded CSV inserted into a DB. Input: multipart upload, attacker-controlled. Risks: size (DoS), content (CSV injection in spreadsheet apps, SQL injection via row contents, malformed encoding crashing the parser), filename (path traversal), MIME type (claimed-CSV-actually-binary). Output: rows in `user_upload` — injection if templated into SQL anywhere, XSS if displayed unescaped. Dependencies: CSV parser, DB driver, multipart parser — each a CVE candidate. The five-minute thought changes the code: max upload size, streaming CSV reader to bound memory, row/column count validation, parameterized inserts, system-generated filename, escape on display.

## The checklist — paranoid by default

### Input handling

- **Validate before use.** Schema (pydantic / Go struct + validator) and reject mismatches. Type, length, range, allowed-character set.
- **Bound everything with a size.** Max upload size, array length, string length, nesting depth. Unbounded input = DoS waiting.
- **Distrust filenames.** Never use an uploaded filename as a path. System-side identifier; store the original separately, escape on output.
- **Distrust MIME types / Content-Type.** Claims, not facts. Sniff the content if the type matters.

### SQL and other injection

- **Parameterized queries always.** No string concatenation into SQL. The driver handles escaping; don't re-implement it.
- **Same for shell, LDAP, XPath, NoSQL.** User input interpolated into a command-shaped string is wrong.
- **Same for HTML, XML, JSON output.** Escape-by-default templating or manual escape on output. Never `f"<div>{user_input}</div>"`.

### Secrets

- **Never in code, logs, or error messages.** Env vars at startup, or a secrets manager.
- **Never in URLs.** URLs are logged in proxies, browser history, CDN logs — a token in a query parameter is a token in a hundred logs you don't own.
- **Never in version control.** Pre-commit hooks (`gitleaks`, `detect-secrets`) for the obvious; review for the subtle.
- **Rotate.** A secret you cannot rotate will eventually leak.

### Authentication and authorization

- **Authenticate before authorizing.** "Who is this?" before "what may they do?" — confusing the two is how privilege escalation happens.
- **Authorize on every request**, not just the first. A session that authorizes once and trusts itself escalates trivially.
- **Default deny.** New endpoints / resources / actions default to no access.
- **Constant-time token comparison.** `secrets.compare_digest` (Py) / `subtle.ConstantTimeCompare` (Go). `==` leaks timing.

### Logging

- **Enough to debug, not enough to leak.** User ids, request ids, error types — yes. Passwords, tokens, full bodies — no.
- **Structured (JSON) logs.** Free-form text drifts and becomes un-grep-able.
- **Wary of logging exceptions verbatim** — some include the offending input; if it contained a secret, it's in the logs now.

### Network

- **TLS everywhere, including internal.** "Inside the VPC" is not a reason. The cluster has guests; the network has snoopers.
- **Verify certificates.** No `verify=False` (httpx/requests), no `InsecureSkipVerify: true` (Go). A legitimate skip (self-signed dev) goes behind a flag, loudly.
- **Pin certificates** for high-stakes upstreams when feasible.

### Concurrency

- **Race conditions are security bugs.** Check-then-act on shared state without locking = TOCTOU. Transactions or locks around state changes.
- **Idempotency for retries.** Duplicate retry must not produce a duplicate side effect — idempotency keys on writes.

## Dependency hygiene

Dependencies are the largest attack surface — most exploits target a transitive dependency, not your code.

### Pin versions

- **Python:** exact versions in `requirements.txt`, or a committed `poetry.lock` / `uv.lock` / `pdm.lock`. Never `>=` for production.
- **Go:** `go.sum` committed (automatic); `go.mod` pins minor versions; `go mod tidy` keeps it honest.

### Scan in CI

Every push to main / PR runs a scanner; build fails above the severity threshold (typically high/critical); lower findings get a triage issue.

- **Python:** `pip-audit --strict` (PyPA, OSV database) or `safety`. CI + locally before a PR.
- **Go:** `govulncheck ./...` — checks whether your code actually *reaches* the vulnerable function; fewer false positives than version-based scanners.

### Review what gets pulled in

Before adding a direct dependency: check the transitive footprint (`pip install --dry-run` / `go mod why`); check maintenance state (last commit, open issues, maintainer count — one maintainer, two years silent = supply-chain risk); consider whether 30 lines of your own code beats a 30-MB transitive tree.

### Update on a schedule

Renovate/Dependabot PRs, triaged weekly. Security-flagged updates merge immediately; routine minor bumps batch.

## When you find a vulnerability

In your code: (1) confirm the exploit path is reachable and what triggers it; (2) patch in private — don't telegraph via public commit log; (3) deploy; (4) rotate credentials if anything could have been exposed; (5) post-mortem: what allowed this, what process change prevents the next.

In a dependency: (1) upgrade if a fix exists — test, deploy; (2) no fix → mitigate at your layer (input validation, capability removal, feature flag), document it; (3) track upstream, upgrade when fixed, remove the mitigation.

## Checklist before declaring code "ready"

- [ ] All inputs validated and bounded.
- [ ] All SQL/shell/LDAP/etc. parameterized.
- [ ] No secrets in code, logs, URLs, error messages, or version control.
- [ ] Authentication on every request; authorization re-checked on every authorized action.
- [ ] All output to HTML/JSON/XML escaped by the templating library.
- [ ] Cryptographic comparisons constant-time.
- [ ] TLS on every network call; certificates verified.
- [ ] Dependency scanner passes with no high-or-critical findings.
- [ ] Pre-commit secret-detection hook installed.
