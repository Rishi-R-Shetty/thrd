# Thrd Spaces — Artifact B: Edge Function Inventory

**Phase 1 slice** · task T3 · Owner: orchestrator · Implementer: T7b (Opus, separate delegation; orchestrator reviews line-by-line against this spec before merge, per amendment A2).

Every privileged operation runs here — anything needing business-logic authorization beyond row ownership. Common envelope required by **every** function (threat-model Layer 5):

Fixed envelope order (amended at T7b review — the original list contradicted its own checklist on kill-switch-vs-JWT ordering):

1. **Kill switch** (constant-key `feature_flags` read — the only pre-auth DB touch): disabled → `503 {"error":"unavailable"}`. Missing flag row = enabled (disabling is opt-in; Phase-1 flags are seeded).
2. **JWT verification server-side.** Verify the signature with the project JWT secret **before parsing any claim**; pin `alg=HS256`; check `exp`/`nbf`; require `role=authenticated` and a UUID `sub`. Derive `caller_id` only from the verified `sub`. Never read a user id from the request body for authorization.
3. **Rate limit** per-user and per-IP (limits below), atomically via the `consume_rate_limit` RPC; over-limit → `429 {"error":"rate_limited"}`.
4. **Validate + effect.**
5. **Audit write** to `audit_log` (one row per **identified** invocation — success or failure — with `outcome` in metadata). Unauthenticated/kill-switch rejections are console-logged only, never DB-written: an anonymous caller must not be able to grow `audit_log` unboundedly (Tier-4 cost amplification). Audit failures never change an already-computed response.
6. **Error shape:** `{"error": "<stable_code>"}` only, plus `500 internal` for anything unexpected. No SQL, no schema names, no stack traces, no existence oracles beyond what a function's spec explicitly allows.
7. **Secrets:** service-role key and `THRD_JWT_SECRET` from Edge Function env only; never in responses, logs, or client code.

**Deployment posture:** platform `verify_jwt` stays default-ON (belt and suspenders — but note the public anon key is itself a validly-signed JWT that passes the gateway, so the in-function `role=authenticated` check is load-bearing, not redundant). Missing-token requests therefore get the gateway's 401 shape rather than ours; acceptable. Set the verification secret with `supabase secrets set THRD_JWT_SECRET=…` per environment.

> The `rate_limit_counters` and `feature_flags` tables are created in migration `0002_edge_function_support.sql` (T7b writes it; both tables RLS-enabled, zero client policies, hostile-test asserted).

---

## 1. `delete_account`

App Store 5.1.1(v) + DPDP erasure. Two-step server flow: grace-mark now, purge job later.

| | |
|---|---|
| **Route** | `POST /functions/v1/delete_account` |
| **Input** | `{ "confirm": true }` — nothing else. Caller identity from JWT only. |
| **Authorization** | `caller_id` = verified JWT sub. A user can delete only themselves. Idempotent: repeat calls while already in grace return `200 {"status":"pending_deletion","purge_after":…}`. |
| **Effect** | Set `users.deletion_requested_at = now()` (concurrency-guarded, idempotent); then invalidate all sessions/refresh tokens via the admin API — *best-effort*, since the admin API cannot join a DB transaction: the grace mark is the source of truth and the purge job re-revokes at hard-delete (amended at T7b review). Audit `account_delete_request`. The nightly purge job (pg_cron, spec'd Phase 2) hard-deletes PII after 30 days: `auth.users` row (cascades to `public.users`), tickets, memberships, blocks either direction; reports and audit rows are retained but re-keyed to `sha256(user_id || server_pepper)` for legal retention. |
| **Grace behavior** | `public_profiles` already excludes grace-period users (view predicate). Sign-in during grace → offer cancel-deletion flow (clears the timestamp, audits `account_delete_cancelled`). |
| **Rate limit** | 3/user/day, 10/IP/hour. |
| **Audit** | `action: "account_delete_request"`, metadata `{ device_id?, outcome }`. |
| **Errors** | `401 unauthorized` (bad/missing JWT) · `400 not_confirmed` (`confirm` ≠ true) · `429 rate_limited` · `503 unavailable`. |

## 2. `submit_report`

The Guideline 1.2 reporting path. Client access to `reports` is fully denied; this is the only write.

| | |
|---|---|
| **Route** | `POST /functions/v1/submit_report` |
| **Input** | `{ "subject_type": "user"\|"event"\|"community"\|"message", "subject_id": uuid, "reason": "safety"\|"harassment"\|"spam"\|"other", "detail": string? ≤500 }` |
| **Authorization** | `reporter_id` = verified JWT sub — the body never carries it. Validate `subject_type/subject_id` refers to an existing row of that type (generic `404 not_found` if not — do not distinguish "exists but hidden from you"). Self-reports rejected (`400 invalid_subject`). |
| **Dedupe** | If an `open` report by this reporter on this subject exists, return `200 {"status":"already_reported"}` — no duplicate row (report-spam vector). |
| **Effect** | Insert report (`status: 'open'`); audit; `reason = safety` additionally enqueues to the Tier-1 queue (4h SLA — Phase 3 queue; until then, email alert to the monitored support address). |
| **Rate limit** | 10/user/hour, 30/user/day, 20/IP/hour. Limits exist to stop weaponized mass-reporting; genuine safety reports are far below them. |
| **Audit** | `action: "report_submit"`, metadata `{ subject_type, subject_id, reason, outcome }`. |
| **Errors** | `401 unauthorized` · `400 invalid_subject` / `400 invalid_reason` · `404 not_found` · `429 rate_limited` · `503 unavailable`. |

## 3. `manage_block` (added by D4)

Blocking affects another user → Edge Function per threat-model rule 8. Only write path to `blocks`.

| | |
|---|---|
| **Route** | `POST /functions/v1/manage_block` |
| **Input** | `{ "action": "block"\|"unblock", "user_id": uuid }` — `user_id` is the *target*; `blocker_id` = verified JWT sub. |
| **Authorization** | Caller manages only their own block list. Target must exist (`404 not_found`); self-block rejected (`400 invalid_target`). |
| **Effect** | `block`: upsert `(blocker_id, target)` — idempotent. `unblock`: delete the row — idempotent, `200` even if absent (don't leak prior state through errors). Phase 2 hangs invisibility propagation (feed exclusion, attendee lists, channel pruning) on this single choke point. |
| **Invariant** | The target is never notified and can never detect the block through this API's responses or timing. |
| **Rate limit** | 20/user/hour, 100/user/day (mass-block spam), 30/IP/hour. |
| **Audit** | `action: "block"` or `"unblock"`, metadata `{ target: <uuid>, outcome }`. |
| **Errors** | `401 unauthorized` · `400 invalid_action` / `400 invalid_target` · `404 not_found` · `429 rate_limited` · `503 unavailable`. |

---

## 4. `rsvp_event` (Phase 2 — spec'd in T12, built in T16 under the A2 review gate)

The only write path to `tickets` in Phase 2 (free events). Capacity is decided inside the function's transaction — client counts are never trusted.

| | |
|---|---|
| **Route** | `POST /functions/v1/rsvp_event` |
| **Input** | `{ "event_id": uuid, "action": "rsvp" \| "cancel" }` — identity from JWT only. |
| **Authorization** | Event must be `published`, `starts_at` in the future (else `400 event_not_open`; drafts and unknown ids both return `404 not_found` — no draft-existence oracle). Tier-0 cap (threat-model Layer 3): callers with `verification_status = 'none'` may RSVP only to free events with `capacity <= 20` (`403 verification_required`); read `verification_status` server-side inside the transaction. Paid events: `400 event_not_open` in Phase 2 (purchases are Phase 3). |
| **Effect (one transaction, `SELECT … FOR UPDATE` on the event row)** | `rsvp`: existing active ticket → idempotent 200 with current status. Else insert ticket `going` if `capacity IS NULL OR rsvp_count < capacity`, else `waitlist`; increment `rsvp_count` only for `going`. `cancel`: mark own ticket `cancelled`; if it was `going`, decrement and promote the oldest `waitlist` ticket to `going` (net count unchanged on promotion). |
| **Response** | `200 { "status": "going" \| "waitlist" \| "cancelled", "rsvp_count": int }`. |
| **Rate limit** | 30/user/hour, 60/IP/hour (rapid RSVP-then-cancel is a Layer-9 anomaly signal — audit rows feed it). |
| **Audit** | `action: "rsvp"` or `"rsvp_cancel"`, metadata `{ event_id, outcome, resulting_status }`. |
| **Errors** | envelope codes + `400 event_not_open` · `403 verification_required` · `404 not_found` · `400 invalid_action`. |
| **Grants (migration 0004)** | service_role: SELECT/INSERT/UPDATE column-scoped on `tickets`; UPDATE (`rsvp_count`) on `events` (D5 pattern). |

## 5. `purge_deleted_accounts` (Phase 2 — spec'd in T12, built in T16)

Nightly pg_cron job (03:30 IST) completing `delete_account`'s 30-day grace.

| | |
|---|---|
| **Trigger** | pg_cron schedule, not HTTP. **Job owner: `postgres`** — this is the SOLE, documented exception to audit_log immutability: re-keying purged users' audit rows requires UPDATE, which every role below the owner has revoked. No other code path may run as owner. |
| **Effect (per user with `deletion_requested_at < now() - interval '30 days'`)** | (1) audit rows: `user_id → NULL`, metadata gains `{ "purged_user": sha256(user_id \|\| server_pepper) }` (pepper from a vault secret — uuid column can't hold a hash, hence NULL + metadata); (2) `DELETE FROM auth.users` → cascades to `public.users`, tickets, memberships, blocks (both directions), reports.reporter cascade; (3) one summary audit row `{ action: "purge_run", metadata: { purged: n } }`. |
| **Idempotency** | re-running skips already-purged users (grace predicate no longer matches). |
| **Kill switch** | `feature_flags` row `fn:purge_deleted_accounts` checked at entry. |
| **Errors** | failures logged, job never partially re-keys without deleting (re-key and delete per-user in one transaction). |

## Deferred to later phases (inventory stubs — spec before build)
| `create_community` / `join_community` | 3 | Rule-8 membership mutations, tier logic. |
| `create_event` | 3 | RRULE validation, tier-2 gate for paid, venue acceptance. |
| `purchase_ticket` | 3 | Server-side price lookup, payment intent, PCI SAQ-A boundary. |
| `checkin_ticket` | 3 | Verify signed QR JWT within event window. |
| `csam_scan_gate` | 3 | Storage-write trigger; blocks image queryability until scanned (unlocks D2 avatars). |
| `ban_user` | 3/4 | One-transaction propagation across sessions, tickets, memberships, channels. |

**Review checklist for T7b (orchestrator applies line-by-line):** JWT verified before any DB touch · identity only from JWT · rate limit before effect · audit written on every path including errors · kill switch checked first · error bodies match the stable codes above exactly · no `service_role` value ever logged · every DB statement parameterized.
