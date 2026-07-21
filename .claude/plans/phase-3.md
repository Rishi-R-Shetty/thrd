# Phase 3 Plan — Community Toolkit (Weeks 8–12)

**Status:** DRAFT — Loop 1, produced 2026-07-17. Awaiting user approval before Loop 2. Phase 2 (T18–T21) continues in parallel on Opus; this plan is prepared ahead.
**Sources:** PRD §4 Phase 3 + §2 entities + §3 Tabs 2/3/4 · threat-model.md §5 Phase 3 must-haves (CSAM scan, moderation queue, moderator scopes, KYC for paid hosting, refund flow) + Layers 6/8/10 · app-store-plan.md (§1.2 UGC filter, §3.1.1 IAP-vs-external, §5.1.1 deletion) · Artifact A/B · decisions **D12** (erasure integrity — the D11 resolution), **D13** (T18 scope), **D14** (envelope order), D2 (CSAM unlocks avatars), D5 (column-scoped grants) · the Phase 2 security audit (`docs/security/audit-phase2-2026-07.md`) · Phase 2 backend facts (probe-extracted, cited to migration lines).

## Exit criterion (verbatim from PRD)

> **Exit criteria:** a host can run a recurring weekly event end-to-end without leaving the app.

Plus threat-model §5 Phase 3 must-haves: **CSAM scanning** (storage-write path, unlocks D2 avatars/covers), **moderation queue**, **community moderator scopes**, **KYC for paid hosting**, **refund flow**.

## Decision-gated / user-input-required before the affected tasks start

1. **Payment processor (Fable priority #4 — separate decision doc, blocks T33/T34).** IAP vs Stripe vs Razorpay per Guideline 3.1.1. Real-world event tickets are a *physical service* → external payment permitted (app-store-plan §3.1.1). Adding Stripe/Razorpay is a **paid dependency → requires user sign-off** (CLAUDE.md decision authority). The payment-architecture doc is produced before T33 is delegated.
2. **KYC provider (Onfido / HyperVerge — blocks T34 paid-host gate).** Tier-2 verification for paid hosting + payouts (threat-model Layer 3/8). Paid dependency → user sign-off.
3. **Recurrence model — RESOLVED by this plan (see T27):** hybrid materialization (canonical `event_series` template + bounded rolling materialization of each occurrence as an ordinary `events` row). Chosen because `tickets`/capacity/`rsvp_event_tx` are hard-keyed to one `events` row per RSVP-able thing; any other model silently breaks per-occurrence RSVP, capacity, or tier counting. Zero delta to `rsvp_event_tx`.

## Ground-truth backend facts this plan builds on (probe-verified)

- **Enums** (0001:20-30) are canonical; Models/ extends via feature-layer extensions only (D10). Phase 3 adds none unless noted.
- **Genuinely missing vs PRD §2** (build from scratch): Message/Channel (Phase 4, not here), **Community Board posts** (no table, not even spec'd), **push tokens** (none), **notification_outbox** (none), **storage buckets + CSAM pipeline** (none — `avatar_url`/`photos`/`cover_url` are text columns with no write path), **KYC/verification workflow** (only the `verification_status` enum stub + tier-0 read exist). **Partially stubbed:** `tickets.qr_code_token` + `checked_in_at` + `ticket_status='checked_in'` (bare, no issuance/scan code); `community_memberships.events_attended_count` + `communities.member_count` (columns exist, **no maintenance code anywhere**).
- **RESTRICT FKs** `events.host_id`, `communities.creator_id` (the D11/D12 landmine) — resolved in T22.
- **Envelope** `serveFn(config, handler)` gives every new function the full Layer-5 envelope for free (`_shared/envelope.ts`); new functions declare `FnConfig` + a `Handler`.

---

## Ordered task list

**Dependency spine:** T22 (erasure integrity) → unblocks everything that adds host/creator rows. T23 (hardening) parallel. T24 (Models) → gates all UI. Community stream {T25→T26→T27}. Events stream {T28→T29→T30→T31} (needs T22 + T24). Push T32 (needs T22's outbox). CSAM/storage T33 (needs payment/KYC only for the paid gate; avatar unlock is independent). Paid ticketing T34 (needs payment decision + T33 KYC). Moderation T35. T36 exit.

Model policy (CLAUDE.md): schema/architecture/security-SQL → **orchestrator (Fable)**; view/repository/wizard → **Opus**; boilerplate/DTO/seed → **Sonnet**. A2-style review gate (orchestrator line-by-line vs Artifact B before merge) on every Edge Function and every migration touching RLS/grants/erasure.

---

### T22 — Erasure integrity: D12 migration + `delete_account` rework — **Orchestrator (Fable); A2 gate**
Resolves D11/D12 and audit F3/F8/F10. **Must precede communities/events write paths** (they add RESTRICT-locked rows).
- **Writes:** `supabase/migrations/0006_erasure_integrity.sql` — `events.host_id`/`communities.creator_id` → nullable + `ON DELETE SET NULL`; `notification_outbox` table (RLS default-deny, zero client policies, `service_role` INSERT, delivery-worker SELECT/UPDATE); `communities.archived_at` + `communities_select_public` gains `and archived_at is null`; grace-start cancellation `SECURITY DEFINER` RPC owned by `postgres`; `rsvp_event_tx` grace guard (action=`rsvp`) + cancel-on-cancelled-event fix; segmented + complete-rekey + durable-skip + batched-commit rewrite of `purge_deleted_accounts`; column-scoped `service_role` grants per D12. `supabase/functions/delete_account/` rework (call the grace RPC; add dry-run preflight). Artifact B §1/§4/§5 updated. EventDetail null-host fallback is a small client sub-task (Opus, folded or split as T22.1). Hostile-suite additions: purge of a host/creator now succeeds via SET NULL; draft/sole-member rows deleted; completed events retained host-null; grace blocks RSVP; attendee can cancel on a cancelled event; complete UUID re-key (subject_id/target/reports.subject_id); durable `purge_skipped` row on a forced failure.
- **Exit:** fresh stack 0001→0006 applies; a user hosting an event + owning a community is fully purged (no RESTRICT throw); DPDP segmentation asserted; grace/cancel behaviors asserted; audit re-key leaves no residual UUID anywhere (queried, not eyeballed).

### T23 — Phase-2 security hardening pass — **Orchestrator (Fable) + Sonnet (tests); A2 gate**
Absorbs audit F2, F4, F5/D14, F6, F7, F11, F12, F15, F17 + the F9/F16/F18 test gaps.
- **Writes:** `supabase/migrations/0007_phase2_hardening.sql` (column-scope `tickets` grant excluding `qr_code_token` (F4); geo RPCs gain `LIMIT`+keyset (F11) and a per-user `consume_rate_limit` gate (F6); `rate_limit_counters` nightly sweep cron (F7); `revoke all … from anon` on definer views (F15); `alter function consume_rate_limit owner to postgres` (F17)); `_shared/http.ts` client-IP fix — rightmost/platform hop, not leftmost (F2); `_shared/envelope.ts` reorder — JWT before kill-switch DB read (F5/D14); `_shared/jwt.ts` fail-closed on missing/non-numeric `exp` (F12); Artifact B envelope wording amended. Hostile suite: JWT alg-confusion/expired/no-exp → 401 (F9); 401/503 write zero audit rows, identified failure writes exactly one (F16); `audit_log` DELETE-immunity vs service_role (F18).
- **Exit:** hostile suite green including all new negative cases; geo RPC rejects an unthrottled burst; spoofed XFF no longer escapes the per-IP cap.

### T24 — Models/: Phase 3 entities + decoding tests — **Sonnet**
- **Writes:** `Models/{EventSeries,BoardPost,PushToken,NotificationOutbox}.swift`; extend `Community`/`CommunityMembership`/`Event`/`Ticket` write-DTOs (create/join/membership-role/paid fields); `Models/` extensions for any new UI affordance enums (D10 — never redeclare). `thrdspacesTests/ModelsTests.swift` round-trips every field byte-for-byte against the T22/T25/T27 migrations.
- **Exit:** build+tests green; enum raw values asserted verbatim vs the SQL enums.

### T25 — Community write path: create/join/manage-membership Edge Functions — **Orchestrator (SQL/grants) + Opus (function bodies); A2 gate**
- **Writes:** `supabase/migrations/0008_communities_write.sql` (grants + `member_count`/tier maintenance inside the functions' transactions — the counters currently have no maintenance code; roles/tiers per enums; tier progression driven by `events_attended_count` thresholds — document the ladder); `supabase/functions/{create_community,join_community,manage_membership}/` (rule-8 mutations, envelope, grace-guarded per D12). Artifact B stubs (§Deferred) promoted to full specs first (orchestrator), then built.
- **Exit:** create→join→promote→leave curl matrix green; `member_count` correct under a concurrent join race; hostile: non-member can't read a private community's members; only a moderator+ can promote; blocked pairs excluded.

### T26 — Communities tab UI — **Opus**
- **Reads:** T24/T25, PRD §3 Tab 2.
- **Writes:** `Features/Communities/` — My Communities (next-event badge), Suggested-for-you, Community Home (cover, description, tier badge, upcoming events, members grid). UI Excellence Standard applies (matched-geometry card→home, staggered reveal, skeletons, haptics on join, reduce-motion fallbacks).
- **Exit:** sim renders seeded communities; join flow end-to-end; a11y + Dynamic Type pass; blocked host's community absent.

### T27 — Community Board (posts + pins) — **Orchestrator (SQL/RLS) + Opus (UI); A2 gate**
- **Writes:** `supabase/migrations/0009_board.sql` (`board_posts` table — id, community_id, author_id, body, is_pinned, created_at; RLS: members read, author/moderator write, block-pair excluded; no client `SELECT *`); moderation hooks (soft-hide for report queue T35); `Features/Communities/CommunityBoard*.swift`.
- **Exit:** post/pin/threaded-reply render; only members read; moderator can pin/remove; hostile: non-member denied, blocked author invisible.

### T28 — Event series + recurrence backend — **Orchestrator (schema) + Opus (function); A2 gate**
Hybrid materialization (see decision above).
- **Writes:** `supabase/migrations/0010_event_series.sql` — `event_series` (id, host_id `ON DELETE RESTRICT`—same D12 handling, community_id, template fields, rrule text, timezone, window_horizon); `events.series_id` nullable FK `ON DELETE CASCADE` + **partial unique(series_id, starts_at)**; `create_event`/`manage_series` Edge Function (RFC-5545 RRULE validation, sole events INSERT path, expands the RRULE in the series' IANA timezone in TS and persists a bounded window of occurrence rows); `materialize_series_window()` SQL cron (pg_cron, mirrors `purge_deleted_accounts` — SQL not HTTP, kill switch, idempotent on the partial unique, nightly top-up). `rsvp_event_tx` unchanged.
- **Exit:** create a weekly series → N occurrence rows materialized, each RSVP-able independently with its own capacity/`rsvp_count`; `nearby_events` returns only in-horizon occurrences (never an unbounded series); cron top-up idempotent; **regenerate is additive-only** (never DELETE+reinsert an occurrence — would cascade-delete its tickets and wipe check-ins/tier counts — hostile-tested); edit-series applies only to future occurrences with zero non-cancelled tickets.

### T29 — Event creation wizard (4 steps) — **Opus**
- **Reads:** T28, PRD §3 Tab 3.
- **Writes:** `Features/Create/EventWizard*.swift` — Basics → Venue (search Spaces / drop pin) → Schedule (weekly/biweekly/monthly recurrence UI → RRULE) → Tickets (free RSVP / capacity / paid — paid CTA gated behind T34 + tier-2). UI Excellence Standard.
- **Exit:** sim creates a free recurring event end-to-end → occurrences appear in Discover; paid path shows the tier-2/verification gate copy until T34; a11y pass.

### T30 — Host dashboard: RSVP list + analytics — **Opus**
- **Writes:** `Features/Create/HostDashboard*.swift` — RSVP list (per occurrence), attendance analytics (attendance rate, repeat-attendee %, growth). Cross-occurrence queries (series-aware).
- **Exit:** dashboard renders seeded series analytics; host-only RLS enforced (`tickets_select_own_or_host`); no attendee PII beyond the host-scoped columns (post-F4 grant).

### T31 — QR check-in — **Orchestrator (signed-JWT design) + Opus (scanner + function); A2 gate**
Completes the PRD exit criterion (run an event end-to-end) and drives tiers.
- **Writes:** `supabase/functions/checkin_ticket/` (verify a signed QR JWT tied to `ticket_id+event_id+user_id`, valid only in the event window, per threat-model Layer 8; sets `checked_in_at`, increments `community_memberships.events_attended_count`, advances tier at thresholds); QR issuance (short-TTL signed JWT) in `rsvp`/ticket read; `Features/Create/CheckInScanner.swift` + attendee QR view.
- **Exit:** issue→scan→`checked_in` in the window; expired/out-of-window/forged QR rejected; tier advances after threshold check-ins; **North-Star metric (verified check-ins) now has a real event.**

### T32 — Push notifications: tokens + outbox delivery + reminders — **Orchestrator (arch/SQL) + Opus (client); A2 gate**
Design (probe-planned; APNs-direct, no new vendor):
- **Writes:** `supabase/migrations/0011_push.sql` — `push_tokens` (user_id, device-bound via the Keychain device UUID from threat-model Layer 2, token, platform, RLS own-rows-only, APNs-410 invalidation column); reuse T22's `notification_outbox` as the queue (recipient, category, payload, collapse_id, scheduled_for, sent_at, status). `supabase/functions/push_sender/` — invoked by pg_cron via `pg_net` (postgres-owned, documented envelope deviation like the purge job: no user JWT — a service-context guard, not the `role=authenticated` path); signs the APNs ES256 `.p8` JWT in Deno (key in a `THRD_` secret; sandbox vs prod topic; per-category `apns-push-type`/priority). Reminder scanner cron writes 24h/2h outbox rows (indexed on `scheduled_for`), dedupe/collapse, event-cancelled invalidation. Preference check at **outbox-write time** (per-category booleans on `users` or a `notification_prefs` table). Threat-model rule 10: **no DM/message body** in the payload; Guideline 4.5.4: per-category opt-in, no promotional pushes. Client: APNs registration + token upload + Settings per-category toggles.
- **User actions:** Apple Developer APNs `.p8` key creation; `THRD_APNS_*` secrets; Push Notifications capability + entitlement in Xcode.
- **Exit:** a scheduled reminder fires on device (or is proven via outbox+sender logs); cancelled-event reminders suppressed; no body leak on lock screen; cost-amplification guard — outbox is **never** client-writable.

### T33 — Storage buckets + CSAM scan pipeline — **Orchestrator (storage RLS/trigger) + Opus (upload UI); A2 gate**
Unlocks **D2** (avatar uploads) + event/community covers + space photos. Non-negotiable guard: CSAM scan in the write path before any image is queryable.
- **Writes:** `supabase/migrations/0012_storage_csam.sql` — buckets (avatars/covers/photos) with storage RLS (own-folder writes, no public read until scanned); a `quarantine`→`clean` state column; Storage-trigger → `csam_scan_gate` Edge Function (PhotoDNA/Cloudflare CSAM tool at the write path; positive → block, quarantine account, NCMEC report per Layer 6); images become queryable only after a clean scan. Client upload paths for avatar/cover/photos behind the gate.
- **Exit:** upload → not queryable until scanned; a seeded positive test-hash is blocked+quarantined (using the provider's test material, never real content); no image column serves an unscanned URL. **Provider choice/keys = user action** (which CSAM provider) — flag before build.

### T34 — Paid ticketing + KYC gate + refund flow — **Orchestrator (arch) + Opus; A2 gate — BLOCKED on payment + KYC decisions**
Per the payment-architecture doc (Fable #4) and threat-model Layer 8.
- **Writes:** `supabase/functions/{purchase_ticket,refund_ticket}/` (server-side price lookup — client price ignored; capacity+payment intent in one tx; PCI SAQ-A boundary — never touch card data; payout only to tier-2 hosts); KYC integration for tier-2 (Onfido/HyperVerge — store only pass/fail + reference hash, Layer 3); chargeback/refund flow from day one. `Ticket.type='paid'` path. Client purchase + refund UI.
- **Exit:** paid ticket end-to-end with a test card (external processor); refund tested; tier-1/unverified host cannot receive payout; price tamper rejected; IAP not triggered on any physical-service flow (Guideline 3.1.1).

### T35 — Moderation queue + community moderator scopes — **Orchestrator (SQL scopes) + Opus (UI); A2 gate**
threat-model Layer 6 + app-store-plan §1.2.
- **Writes:** `supabase/migrations/0013_moderation.sql` — report queue tables + SLA fields (Tier-1 4h / Tier-2 24h / Tier-3 72h); moderator-scoped permissions (remove posts in own community, **no member PII beyond public profile**); shadow/soft-ban support. Moderator UI + report-review surface.
- **Exit:** report → queue with SLA; moderator can action own-community content only; scope hostile-tested (moderator can't read member PII / other communities); soft-ban hides content without a hard-ban evasion signal.

### T36 — Phase 3 exit verification — **Orchestrator (Fable)**
- **Exit:** PRD criterion demonstrated on device — a host creates a **recurring weekly event**, attendees RSVP per occurrence, host runs QR check-in, tiers advance — end-to-end without leaving the app. All threat-model §5 Phase 3 must-haves shipped (CSAM, moderation queue, moderator scopes, KYC-gated paid hosting, refund). Full hostile suite green (incl. all audit F-items). `service_role`/secret greps clean. Completion notes + CLAUDE.md learnings + Phase 4 draft. Stop for user review.

---

## Non-negotiable guards active this phase

CSAM scan in every image write path before queryability (T33 — the guard that gated D2 since Phase 1) · KYC data never stored, only pass/fail + hash (T34) · server-side price/capacity, client values ignored (T34) · signed short-TTL QR JWTs tied to ticket+event+user, event-window only (T31) · moderator scopes never expose member PII (T35) · blocked-user invisibility now also on board posts + community members + push (T27/T35, extends T18/D13) · DPDP erasure completeness (T22/D12) · no notification body leak on lock screen (T32) · RLS default-deny + column-scoped grants on every new table/view/RPC · accessibility labels + Dynamic Type everywhere · UI Excellence Standard on every screen-touching task.

## Risks / notes for the user

1. **Two paid dependencies need sign-off before their tasks start:** payment processor (T34) and KYC provider (T34). The CSAM provider (T33) is also a vendor choice. None block the community/event/recurrence/check-in core (T22–T31), which is where the PRD exit criterion lives — sequence the paid stream last.
2. **This is the largest phase** (PRD Weeks 8–12; ~15 tasks). Recommend approving it in two waves: **Wave A** (T22–T24 foundation + T25–T31 community/events/check-in → satisfies the PRD exit criterion) and **Wave B** (T32 push, T33 CSAM, T34 paid, T35 moderation → the security/compliance must-haves for submission). T36 closes both.
3. **Recurrence DST guard:** launch cities are Asia/Kolkata (UTC+5:30, no DST) so today's math is safe, but occurrence generation MUST expand the RRULE in the series' IANA timezone — never `dtstart_utc + N*7 days`. Same class as the existing 22:00-UTC-cron ponytail; the moment any DST region is added, naive math drifts an hour.
4. **Phase 2 must finish first for the exit demo:** T18 (blocked invisibility, widened per D13) + T20 (seed) + hosted deploy are prerequisites for a live Phase 3 end-to-end.
5. **Fable-priority docs still queued** (#3 recommendation engine, #4 payment, #5 multi-city ops, #6 scaling) — #4 is on the critical path for T34; the others are Phase 4 foundation / ops and can follow.

## Task approval log

*(Loop 3 appends one line per approved task here.)*

- **T22 split into T22a (SQL, done) + T22b (app-layer, next).** The migration and the coordinated Edge/client changes require different lock-step, so they're separate commits.
- **T22a — DONE + VALIDATED** (2026-07-19, orchestrator; migration `0006_erasure_integrity.sql`). Resolves the D11 landmine (D12) and audit F3/F10: `events.host_id`/`communities.creator_id` → nullable + `ON DELETE SET NULL` (no tombstone user); `purge_deleted_accounts` rewrite with DPDP segmentation (delete sole-owner drafts + cancelled-no-attendee events + sole-member communities; SET NULL-retain completed/multi-attendee/multi-member as counterparty data), **complete uuid re-key** (audit actor + metadata `subject_id`/`target`, and erase reports where the purged user is the subject), and a **durable `purge_skipped`** row (no more silent NOTICE); `rsvp_event_tx` openness gate now applies to `rsvp` only so an attendee can **cancel on a host-cancelled/completed event** (D12 §4 — was audit's cancel-lock bug); `notification_outbox` table (schema) + `communities.archived_at` + policy. Verified on a fresh 0001→0006 stack: new `supabase/tests/erasure_integrity_tests.sql` PASSED (host+creator fully purged, segmentation, complete re-key, durable skip); existing hostile suite `ALL PASSED` (no regression); cancel-on-cancelled confirmed + rsvp still blocked.
- **T22b — TODO** (app-layer, needs lock-step Edge/client): grace-start cancellation RPC (postgres-owned SECDEF — cancels future published hosted events + their tickets, promotes moderators, writes `notification_outbox` rows with no-disclosure copy); `delete_account` calls it + dry-run preflight; `rsvp_event_tx` grace-guard returning a new `account_pending_deletion` result + the matching `rsvp_event/index.ts` + client copy; EventDetail null-host fallback ("Host unavailable"); Artifact B §1/§4/§5 update. Also **F8** (purge batched-commit procedure — a scale-only lock optimization; correctness already holds in T22a) folds in here or a later hardening pass.
