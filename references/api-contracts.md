# API contracts

Open when adding, modifying, or removing any externally-visible interface: REST endpoint, gRPC method, protobuf/Avro schema, message payload, webhook event, CLI flag, public SDK function. A change to a contract is a change every caller must absorb — the discipline is making absorption cheap.

## What counts as a breaking change

| Change | Breaking? |
|---|---|
| Add a new optional field to a response | No |
| Add a new endpoint / method | No |
| Add a *required* field to a request | **Yes** |
| Remove a field from a response | **Yes** |
| Rename a field (even with alias) | **Yes** to old clients |
| Tighten a type (`string` → `enum`, `int` → `uint`) | **Yes** |
| Loosen a type | Compatible *forward*, **breaking backward** for parsers that validate |
| Add a value to an enum | **Yes** unless clients handle unknown |
| Change semantics of an existing field | **Yes** (worst kind — silent) |
| Change error envelope / error codes | **Yes** |
| Add a new event type to a stream | Maybe (depends on consumer's "unknown event" policy) |
| Re-order array elements when order wasn't promised | No, but document order if callers depend on it |

Rule: **Adding optional things is safe. Removing or constraining anything is not.** When in doubt, treat as breaking.

## Versioning strategies

| Strategy | Use when |
|---|---|
| **URL path** (`/v1/orders`, `/v2/orders`) | Public APIs, broad client base, caches need stable URLs. Default for REST. |
| **Header** (`Accept: application/vnd.acme.v2+json`) | URL stability non-negotiable; you own the CDN/cache key. |
| **Query parameter** (`?version=2`) | Rarely. Caches misbehave; clients copy URLs. |
| **gRPC / protobuf package version** (`acme.v1`, `acme.v2`) | gRPC default. New version = new service definition. |
| **No version, evolve in place** | Internal API, single deployment unit, all callers updated atomically. |

Pick one and stick to it. Mixing (some endpoints versioned, some not) leaves callers guessing.

## Backward-compatible evolution (the goal)

Most changes don't need a new version. The expand → migrate → contract pattern:

1. **Expand.** Add the new field/behavior alongside the old. Both work.
2. **Migrate.** Update callers to use the new one. Track adoption via per-field telemetry.
3. **Contract.** Once usage of the old hits zero (verified in metrics, not in the doc), deprecate publicly, wait the deprecation window, then remove.

This is the same pattern as DB migrations (`migrations.md`) — for the same reason.

## Deprecation discipline

A deprecation that isn't communicated is a future incident.

- **`Deprecation` header (RFC 9745, March 2025)** on every response from the deprecated endpoint: `Deprecation: @1735689600` (Unix timestamp of when deprecation started).
- **`Sunset` header (RFC 8594)**: `Sunset: Sat, 31 Dec 2026 23:59:59 GMT` — the date the endpoint stops working.
- **`Link: <…>; rel="successor-version"`** pointing to the replacement.
- **Changelog entry** with replacement instructions and a code example.
- **Per-caller email / in-app banner** for known callers.
- **Usage dashboard** with caller breakdown — name and shame (or contact) before sunset.
- **Window: 6–12 months minimum** for public APIs. Shorter is hostile; longer is acceptable if usage is non-zero.
- **Soft-throttle before removal.** Slow the deprecated path (artificial 1-3s latency) for two weeks before sunset to surface holdouts.

Never silent-remove. Never "but no one's using it" without a query that proves it.

## OpenAPI / gRPC schemas as the source of truth

- **Schema-first.** Write the contract before the handler. Generate handlers, clients, and validators from it. Drift between code and spec is a defect class — eliminate by removing the gap.
- **Lint the spec in CI.** Spectral for OpenAPI; `buf lint` for protobuf. Standard rules: required fields documented, error responses present, operation IDs unique.
- **Diff the spec in CI.** `openapi-diff` / `buf breaking` flags breaking changes against the main branch. Fails the build unless the PR is labelled `breaking-change` (which triggers the deprecation playbook, not a merge).
- **Publish the spec.** A repo `spec.yaml` or generated docs site. Callers find it without asking.

## Contract testing — catch the break before prod

Unit tests cover handler logic; integration tests cover the wire. **Contract tests** cover the agreement between two services: consumer says "I expect this shape"; provider proves it.

- **Pact** is the dominant tool. Consumer-driven: consumer writes a contract; provider runs it as a test. Pact Broker holds the contracts; provider's CI verifies on every push.
- **Verification gate.** Provider's CI fails if any consumer's contract breaks. Surface which consumer would break — the deprecation conversation starts there.
- **`can-i-deploy`** check in the deploy pipeline: this version is safe to deploy if all consumers' contracts still pass against it.

Without contract tests, "we changed the API and someone broke" is a discovery in prod.

## Error contracts

Errors are part of the contract, not an afterthought.

- **Envelope is stable.** `{"error": {"code": "string", "message": "string", "details": {...}}}` shape doesn't change across versions. Adding `details` keys is fine; renaming `error` to `err` is breaking.
- **Codes are an enum.** `INVALID_INPUT`, `NOT_FOUND`, `RATE_LIMITED`, `UPSTREAM_TIMEOUT`. Document each. Callers branch on these — not on the message text.
- **HTTP status matches code.** Don't return `200 {"error": ...}` — pre-2010 mistake. 4xx for client, 5xx for server.
- **Trace id in every error response.** `{"error": {..., "trace_id": "..."}}`. Support requests trace back fast.
- **No leaking secrets / stack traces in production errors.** A 500 includes a trace id, not the SQL it failed on.

## Webhooks — outgoing event contracts

Same backward-compat rules apply, with extras specific to delivery:

- **Sign every webhook.** HMAC-SHA256 of `timestamp + body` with a per-tenant secret. Include the timestamp in the header.
- **Receivers must verify signature and reject stale timestamps** (5-minute window). Standard pattern; document it loudly.
- **Idempotency: every event carries an `event_id`** receivers dedup on. See `distributed.md` → idempotency / inbox.
- **Retry policy is part of the contract.** "Up to 7 attempts over 24 hours with exponential backoff" — write it down so receivers know what to handle.
- **Versioned payload.** `{"event_type": "order.placed", "schema_version": 2, "data": {...}}`. Adding fields safe; renaming breaking.
- **Replay endpoint.** `POST /webhooks/{id}/replay` so receivers can re-pull after an outage. Without this they ask, badly.
- **Public schema** of every event type. Same lint + diff + contract-test discipline.

## gRPC / protobuf specifics

- **Field numbers are forever.** Never reuse a field number for a different field. `reserved 5;` when removing.
- **`required` is banned** (proto3 dropped it; proto2 should pretend). Use validation outside the schema.
- **New fields are always optional** at the wire level. Default values flow through.
- **Service names + method names are part of the contract.** Renaming = breaking.
- **Use `buf` for linting and breaking-change detection.** `buf breaking --against '.git#branch=main'` is the gate.

## Anti-pattern fingerprints

- Field renamed without alias / dual-write — breaks every existing client. 🔴
- New `required` field on a request schema — every old client breaks. 🔴
- Enum extended without a documented "unknown value" handling rule for clients. 🟡
- HTTP status `200 {"error": ...}` envelope — abuse of HTTP semantics. 🟡
- No `Deprecation` / `Sunset` header on a known-deprecated endpoint. 🟡
- Spec-only changes (or code-only changes) — drift between OpenAPI / protobuf and handler. 🟡
- No `buf breaking` / `openapi-diff` in CI on the spec repo. 🟡
- Webhook handler with no signature verification or no timestamp window — replay / forgery. 🔴 (security)
- Webhook payload changes without `schema_version` bump and changelog. 🟡
- gRPC field number reused for a different field. 🔴 (data corruption)
- Error code text relied on by callers (not a stable enum) — silent break on copy edit. 🟡

## Checklist

- [ ] Contract change classified: additive / breaking. Breaking goes through deprecation, not the PR pipeline.
- [ ] Schema (OpenAPI / protobuf) is source of truth; handler generated or validated against it.
- [ ] CI lints + diffs the schema; breaking changes block merge unless labelled.
- [ ] Contract tests (Pact or equivalent) cover every consumer of a service-to-service API.
- [ ] Deprecated endpoints carry `Deprecation` + `Sunset` headers and a successor link.
- [ ] Deprecation window ≥ 6 months for public APIs; usage dashboard tracked.
- [ ] Errors: stable envelope, enum codes, trace id, no secrets.
- [ ] Webhooks: HMAC signature, timestamp window, `event_id` dedup, retry policy documented, replay endpoint.
- [ ] gRPC: field numbers reserved on removal, `buf breaking` in CI.
