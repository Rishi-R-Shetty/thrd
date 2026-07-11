# Thrd Spaces — Artifact B: Edge Function Inventory

**Phase 1 slice** · task T3 · Owner: orchestrator · Implementer: T7b (Opus, separate delegation; orchestrator reviews line-by-line against this spec before merge, per amendment A2).

Every privileged operation runs here — anything needing business-logic authorization beyond row ownership. Common envelope required by **every** function (threat-model Layer 5):

1. **JWT verification server-side.** Parse and verify the caller's JWT with the project JWT secret; derive `caller_id` from the verified `sub`. Never read a user id from the request body for authorization.
2. **Rate limit** per-user and per-IP (limits below). Backing store: `rate_limit_counters` table (function-scoped keys, windowed counts); return `429 {"error":"rate_limited"}` with no further detail.
3. **Audit write** to `audit_log` via service client (one row per invocation, success or failure, with `outcome` in metadata).
4. **Kill switch:** read `feature_flags` row `fn:<name>` at entry; if disabled return `503 {"error":"unavailable"}`. Flags table is service-role-only, flipped from the dashboard without a deploy.
5. **Error shape:** `{"error": "<stable_code>"}` only. No SQL, no schema names, no stack traces, no "user not found" vs "wrong password" distinctions.
6. **Secrets:** service-role key from Edge Function env only. It never appears in responses, logs, or client code.

> The `rate_limit_counters` and `feature_flags` tables are created in migration `0002_edge_function_support.sql` (T7b writes it; both tables RLS-enabled, zero client policies, hostile-test asserted).

---

## 1. `delete_account`

App Store 5.1.1(v) + DPDP erasure. Two-step server flow: grace-mark now, purge job later.

| | |
|---|---|
| **Route** | `POST /functions/v1/delete_account` |
| **Input** | `{ "confirm": true }` — nothing else. Caller identity from JWT only. |
| **Authorization** | `caller_id` = verified JWT sub. A user can delete only themselves. Idempotent: repeat calls while already in grace return `200 {"status":"pending_deletion","purge_after":…}`. |
| **Effect** | In one transaction: set `users.deletion_requested_at = now()`; invalidate all sessions/refresh tokens for the user (Supabase admin API); audit `account_delete_request`. The nightly purge job (pg_cron, spec'd Phase 2) hard-deletes PII after 30 days: `auth.users` row (cascades to `public.users`), tickets, memberships, blocks either direction; reports and audit rows are retained but re-keyed to `sha256(user_id || server_pepper)` for legal retention. |
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

## Deferred to later phases (inventory stubs — spec before build)

| Function | Phase | One-line scope |
|---|---|---|
| `rsvp_event` | 2 | Free RSVP: transactional capacity check + waitlist; never trusts client counts. |
| `purge_deleted_accounts` | 2 | Nightly pg_cron job executing the 30-day hard-delete described above. |
| `create_community` / `join_community` | 3 | Rule-8 membership mutations, tier logic. |
| `create_event` | 3 | RRULE validation, tier-2 gate for paid, venue acceptance. |
| `purchase_ticket` | 3 | Server-side price lookup, payment intent, PCI SAQ-A boundary. |
| `checkin_ticket` | 3 | Verify signed QR JWT within event window. |
| `csam_scan_gate` | 3 | Storage-write trigger; blocks image queryability until scanned (unlocks D2 avatars). |
| `ban_user` | 3/4 | One-transaction propagation across sessions, tickets, memberships, channels. |

**Review checklist for T7b (orchestrator applies line-by-line):** JWT verified before any DB touch · identity only from JWT · rate limit before effect · audit written on every path including errors · kill switch checked first · error bodies match the stable codes above exactly · no `service_role` value ever logged · every DB statement parameterized.
