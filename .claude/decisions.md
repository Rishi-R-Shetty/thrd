# Decisions Log

Every orchestrator decision that resolves an ambiguity in the PRD or a Q from `.claude/questions.md` is logged here with a one-paragraph rationale. Append-only. Once a decision is logged, treat it as canonical unless explicitly amended in a new entry.

Format:
```
## D{N} — {short title}
**Date:** YYYY-MM-DD
**Context:** Which phase, task, or question this resolves.
**Decision:** What was chosen.
**Rationale:** Why. What alternatives were considered.
**Impact:** Files, plans, or docs that need updating.
```

---

## D1 — Phase 1 scope includes security/compliance Phase-1 items not listed in the PRD roadmap
**Date:** 2026-07-11
**Context:** Loop 1, Phase 1 planning. PRD §4 Phase 1 lists project setup, schema+RLS, auth, onboarding, profile, location. But `docs/security/threat-model.md` §5 marks "basic report flow, age gate" as Phase 1 must-haves, and `docs/compliance/app-store-plan.md` §1 marks report, block, EULA-accept (Guideline 1.2), in-app account deletion (5.1.1(v)), and Declared Age Range API integration as Phase 1 features.
**Decision:** The Phase 1 plan is the union of all three documents' Phase-1 scope. Report/block/EULA/account-deletion/age-gate are in `.claude/plans/phase-1.md` as tasks T6–T7.
**Rationale:** CLAUDE.md makes the security guards non-negotiable and the compliance plan ground truth; the PRD roadmap is a summary, not an exclusion list. Deferring these creates rework in auth/onboarding flows they must be woven into. This is reconciliation across ground-truth docs, not MVP scope expansion, so it does not require user sign-off under "expanding MVP scope" — but it is surfaced in the phase plan for visibility.
**Impact:** `.claude/plans/phase-1.md` tasks T3, T6, T7.

## D2 — No avatar/image upload in Phase 1
**Date:** 2026-07-11
**Context:** PRD Phase 1 includes "Profile create/edit"; the User entity has `avatar_url`. But the non-negotiable guard requires the CSAM scan pipeline in the storage-write path before any image is queryable, and the threat model ships CSAM scanning in Phase 3.
**Decision:** Phase 1 profile create/edit ships with no image upload of any kind. Avatars render as initials on a deterministic color derived from `user.id`. `avatar_url` stays in the schema (nullable) but no client write path exists until the CSAM pipeline lands (Phase 3).
**Rationale:** Any Phase 1 upload path would violate the CSAM guard. Building the pipeline early would pull a large Phase 3 dependency (storage triggers, PhotoDNA/Cloudflare integration, NCMEC reporting) into Phase 1 for negligible MVP value.
**Impact:** Phase 1 task T7; Phase 3 plan must include "enable avatar upload behind CSAM pipeline."

## D3 — Age-gate fallback when Declared Age Range API is unavailable
**Date:** 2026-07-11
**Context:** No under-18 accounts at launch (non-negotiable guard). Declared Age Range API (iOS 26+) is the primary mechanism per the compliance plan, but it can return nothing (older account, user declines to share, region). KYC only exists at tier-2 (Phase 4).
**Decision:** Phase 1 signup: (1) call Declared Age Range API; under-18 → block account creation with explainer; (2) if no result, require an explicit 18+ self-attestation (unchecked-by-default checkbox, logged with timestamp in the audit trail); (3) age data used ephemerally at the decision point, never persisted beyond the boolean gate result, per the compliance plan.
**Rationale:** Matches the threat model ("enforced via Declared Age Range API where available and KYC for tier-2") — self-attestation is the only remaining lever before tier-2 KYC exists, and it is the App Store norm for 17+ apps. Behavioral under-age flagging remains a Phase 4 item.
**Impact:** Phase 1 task T6; audit-log table in T3 needs an `age_attestation` event type.

## D4 — Block/unblock goes through an Edge Function, not direct table access
**Date:** 2026-07-11
**Context:** Loop 1/T3. The phase plan gave `blocks` a client-side RLS surface, but threat-model.md §3 rule 8 says: "Every mutation that affects another user (invite, block, add-to-community) goes through an Edge Function, not direct table access." Blocking affects the blocked user (invisibility propagation from Phase 2 on).
**Decision:** No client INSERT/DELETE policies on `blocks`; clients keep SELECT on their own rows only. A third Phase-1 Edge Function `manage_block` (action: block|unblock) is added to T7b's scope, with the standard JWT-verification/rate-limit/audit/kill-switch envelope. `blocker_id` is derived from the verified JWT.
**Rationale:** Rule 8 is explicit and blocking is its named example. The Edge Function also buys rate limiting (mass-block spam), a uniform audit trail, and a single place to hang Phase 2 propagation (cache invalidation, channel membership pruning) without a migration.
**Impact:** T3 migration (`blocks` gets SELECT-own policy only); Artifact B gains `manage_block`; T7b writes a third function; T7a's BlockedUsersView calls it.

## D5 — service_role gets minimal column-scoped table grants, not per-mutation SECURITY DEFINER RPCs
**Date:** 2026-07-11
**Context:** T7b review gate. Artifact A/0001 assumed `service_role` (BYPASSRLS) could write reports/blocks/users/audit_log directly, but BYPASSRLS is not a table privilege — under the not-auto-exposed Data API default, service_role held no DML grants and every Edge Function write failed 42501 (verified empirically by the T7b implementer).
**Decision:** Close the gap with minimal, column-scoped grants in 0002 (e.g. `UPDATE (deletion_requested_at)` only on users; `INSERT (reporter_id, subject_type, subject_id, reason, detail)` only on reports). Keep `audit_log` UPDATE/DELETE revoked from service_role. The alternative — one SECURITY DEFINER RPC per mutation — is deferred.
**Rationale:** Column-scoped grants give most of the least-privilege benefit at a fraction of the ceremony; the RPC-per-mutation pattern adds a second authorization layer to maintain in lockstep with Artifact B for no Phase-1 threat it uniquely blocks (functions already hold the service key). Revisit if a function ever needs row-conditional privileges that grants can't express.
**Impact:** 0002 migration; Artifact A's "service_role is the write path" wording now means "column-scoped grants per function"; hostile suite asserts the client roles gained nothing.

## D6 — Two-city launch: defaults and seed volume
**Date:** 2026-07-13
**Context:** Loop 1, Phase 2. User set launch cities to Bengaluru AND Mumbai. PRD assumed one city ("100–200 spaces for launch city"; Discover's default region).
**Decision:** Discover's default region = nearest of {Bengaluru (12.9716, 77.5946), Mumbai (19.0760, 72.8777)} to the last coarse location, falling back to device locale, falling back to Bengaluru. Seed target: 100–200 spaces **per city**. The single `defaultCity` constant (TD2) becomes a two-entry `LaunchCity` enum with a `nearest(to:)` resolver.
**Rationale:** Nearest-city beats a picker (zero-friction default, picker can come later); Bengaluru stays the terminal fallback as the original launch city. Per-city volume keeps the PRD's density intent — halving it across two cities would make both feel empty, defeating the discovery exit criterion.
**Impact:** Phase 2 tasks T14 (defaults), T20 (seed both cities); App Store review-notes region guidance gains Mumbai (Phase 4 doc).

## D7 — Seed-data sourcing: OSM/Overpass, Google Places prohibited for stored data
**Date:** 2026-07-13
**Context:** Loop 1, Phase 2, task T20. User chose "pipeline (Places API or similar), not manual."
**Decision:** The pipeline sources from OpenStreetMap via Overpass (amenity/leisure/tourism tags mapped to our categories), with a validation pass. Google Places is prohibited as a source for any data we persist. Each seeded row carries `source_ref` (e.g. `osm:node/123`) for idempotent re-runs. ODbL obligations: attribution ("© OpenStreetMap contributors") in the app's About screen and website; our spaces table qualifies as a derivative database → share-alike considerations documented in docs/compliance/.
**Rationale:** Google Places ToS forbids storing/caching place details beyond place IDs — a seed pipeline that persists names/coords/addresses into our Postgres would violate it and creates App Store + legal exposure (Tier-5). OSM data is licensed for exactly this use. "Or similar" gives latitude to pick the compliant option.
**Impact:** T20 design; docs/compliance/ attribution note; About screen (small T20 client task).

## D8 — What "coarsened location queries" means, precisely
**Date:** 2026-07-13
**Context:** Loop 1, Phase 2, task T12. The guard says "location queries coarsened via geohash for public reads; exact coordinates only for confirmed attendees within 2h of event start." Venues, however, are public places whose exact pins ARE the product.
**Decision:** Coarsening applies to the USER side of every query: the client snaps its own location to a geohash-5 cell before it ever leaves the device, and the nearby RPCs accept only a snapped cell (server re-snaps defensively; a raw high-precision coordinate is never persisted or logged). Venue (`spaces.location`) pins render exact. Event *meeting-point precision* follows the guard: non-attendees resolve an event to its venue's public location only; any future exact-meet-point field is attendee-gated within the 2h window.
**Rationale:** This is the only reading that satisfies both the threat model (no user movement-pattern leakage — Tier 1 stalking) and the PRD (a map of cafes is useless with fuzzed venue pins). Artifact A already hinted at it; making it explicit before T12 prevents a subagent from fuzzing venue pins or, worse, shipping exact user coords.
**Impact:** T12 RPC contract; T13 client snapping; hostile tests assert the RPC rejects/snaps raw coordinates.

## D9 — Emergency contact for the panic button is device-local only
**Date:** 2026-07-13
**Context:** Loop 1, Phase 2, task T19. The panic button ("one-tap to the local emergency number and to your emergency contact with your location") implies storing an emergency contact. `users` has no such field, and adding server-side PII of a THIRD party (the contact) creates DPDP obligations toward someone who never consented.
**Decision:** The emergency contact (name + phone) lives ONLY in the device Keychain (`KeychainTokenStore`, WhenUnlockedThisDeviceOnly). Never synced, never in Postgres. Panic flow: dial local emergency number + prefilled SMS to the contact with a maps link. Set-up UI lives in the safety-sheet flow and Settings.
**Rationale:** Server-side third-party PII is pure liability with zero product benefit — the contact is only ever used from the victim's own device. Device-local also survives offline, which is exactly the panic scenario. Trade-off: contact doesn't roam across devices; acceptable (re-enter on new device, consistent with device binding).
**Impact:** T19 scope; no schema change; threat-model Layer 7 note at next revision.

## D11 — Purge fail-closes on host/creator users; Phase 3 must resolve the erasure-vs-RESTRICT conflict
**Date:** 2026-07-14
**Context:** T16 A2 review. `purge_deleted_accounts()` hard-deletes `auth.users`, cascading to public.users/tickets/memberships/blocks/reports. But `events.host_id` and `communities.creator_id` are `ON DELETE RESTRICT` (migration 0001) — a deletion-requesting user who hosts an event or created a community throws, and the per-user subtransaction rolls back (re-key + delete both undone), logs a skip, and leaves them eligible for the next run.
**Decision:** Accept this as correct **fail-closed** behavior for Phase 2 (skip-and-log beats orphaned or re-keyed-but-undeleted data, and one bad user must not abort the nightly run). It is genuinely unreachable in Phase 2 — event/community creation is Phase 3. **Phase 3 MUST resolve it**: a DPDP 30-day erasure obligation cannot be silently defeated by a RESTRICT FK. The Phase 3 plan (T-TBD) owns choosing among: (a) block account deletion while the user has active/future hosted events (surface at delete_account time); (b) transfer/anonymize host ownership on purge; (c) cancel-and-notify attendees of a purged host's events. This is logged now so it is not rediscovered as a production incident.
**Rationale:** Silent non-erasure of a user who requested deletion is a Tier-5 regulatory exposure. Phase 2 has no path to trigger it, so blocking Phase 2 on it would be premature; but it must be a named Phase 3 deliverable, not a latent surprise.
**Impact:** Phase 3 plan gains an erasure-integrity task; delete_account (Artifact B §1) may gain a pre-check; no Phase 2 change. Resolved by **D12**.

## D12 — Resolution of D11: ON DELETE SET NULL + grace-start cancellation, not a tombstone user
**Date:** 2026-07-17
**Context:** Loop 1, Phase 3. D11 deferred the purge-vs-RESTRICT erasure conflict to Phase 3. A red-team probe (schema-grounded, every claim cited to migration line) evaluated a proposed tombstone-user design and refuted its core mechanic.
**Decision:** The Phase 3 erasure-integrity task (T22) implements:
1. **No tombstone user.** Because `public.users.id → auth.users(id) ON DELETE CASCADE` (0001:35), a `public.users` tombstone forces a fragile raw `auth.users` insert (GoTrue owns that schema; hand-seeded rows break on upgrade / can be partially sign-in-able) for zero benefit — a re-keyed row and a null-keyed row are equally PII-free. Instead, make `events.host_id` and `communities.creator_id` **nullable** and flip both FKs from `ON DELETE RESTRICT` to **`ON DELETE SET NULL`**. Purge then just `DELETE FROM auth.users`; the cascade nulls residual `host_id`/`creator_id` and RESTRICT never fires. EventDetail renders "Host unavailable" for a null host (add the fallback). (If a named sentinel is ever required, seed it via the Admin API at deploy — never SQL — record the UUID in config, ban it, `profile_visibility='private'`, exclude from `public_profiles`.)
2. **Grace-start cancellation (in `delete_account`, one transaction, via a postgres-owned `SECURITY DEFINER` RPC so `service_role`'s grant surface stays minimal):** set `deletion_requested_at=now()`; cancel future published hosted events (`status='cancelled'`) AND bulk-cancel their `going`/`waitlist` tickets + zero `rsvp_count` in the same tx; for each of the caller's communities, `SELECT … FOR UPDATE` the memberships and if the caller is the last **non-grace** host, promote the oldest moderator (role handoff only — `creator_id` is cleared separately at purge); write `notification_outbox` rows for affected attendees with copy **"This event has been cancelled"** and no disclosure of the host's deletion (DPDP — the reason is the host's personal data). Explicitly decide the in-progress-event rule (recommend: also cancel `starts_at<=now()<ends_at`, and add the null-host EventDetail fallback regardless).
3. **Grace write-blocking enforced in code:** add a `deletion_requested_at` check to `rsvp_event_tx` (action=`rsvp` only → new `account_pending_deletion`/403) and to the Phase 3 `create_event`/`create_community` functions. `service_role` already has `select(deletion_requested_at)` (0002:118). The residual same-second TOCTOU is accepted (such a ticket is purged 30 days later).
4. **`rsvp_event_tx` cancel-on-cancelled-event fix:** today the `event_not_open` guard runs before the rsvp/cancel branch split (0004:99-103), so an attendee **cannot self-cancel** a ticket on a host-cancelled event. Relax so action=`cancel` reaches the cancel branch even when `status IN ('cancelled','completed')`; keep `rsvp` blocked.
5. **Purge segmentation for DPDP (in `purge_deleted_accounts`):** at purge, `DELETE` draft events, future-cancelled events with zero non-host attendees, and sole-member communities (no counterparty → re-keyed retention is *over-retention*, not erasure); `SET NULL`-retain only completed events and cancelled events that had other attendees, and multi-member communities (genuine counterparty/historical interest). Complete the UUID re-key (audit F3: also re-key `audit_log.metadata` `subject_id`/`target` and `reports.subject_id`, not just the actor column). Write a durable `purge_skipped` audit row on the exception path (audit F10). Convert to per-user/batched COMMIT so locks release incrementally at scale (audit F8).
6. **Pre-flight (App Store 5.1.1(v)-compliant):** a dry-run mode on `delete_account` (or a read-only preflight endpoint) returns counts/titles of future hosted events + owned communities so the confirmation screen can say "deleting will cancel these events and hand off/archive these communities" — **informs, never blocks**; one tap proceeds with no external step. Requires added `SELECT` grants on events/communities for `service_role`.
**Schema changes (Phase 3 migration):** FK/nullability flip on `events.host_id` + `communities.creator_id`; new `notification_outbox` table (RLS default-deny, `service_role` INSERT); `communities.archived_at` + `communities_select_public` gains `and archived_at is null`; column-scoped `service_role` grants (`update(status)` on events, `select`/`update(role)` on community_memberships, selects on communities); `rsvp_event_tx` grace guard + cancel fix; EventDetail null-host fallback. No trigger/unique-constraint conflicts exist (no triggers in 0001-0004; `public_profiles`/`attendee_previews` already exclude grace users — which is *why* grace-start cancellation is needed to avoid a broken EventDetail during grace).
**Rationale:** SET NULL is the mechanically-correct, portable satisfaction of the FK that a tombstone only imitates at higher fragility. Segmented purge makes retention DPDP-defensible (counterparty data only). Cancel-and-notify without disclosure balances attendee's right-to-know against the host's erasure right. Cancelling deletion during grace does NOT auto-restore cancelled events (host republishes) — accepted asymmetry.
**Impact:** Phase 3 task T22 (erasure-integrity migration + `delete_account` rework); ties to audit findings F3/F8/F10; Artifact B §1/§4/§5 updated in T22.

## D13 — T18 blocked-invisibility scope widened to public_profiles
**Date:** 2026-07-17
**Context:** Phase 2 audit F1/F1b. T18 (0005_block_invisibility) scoped the blocked-pair exclusion to `attendee_previews`, `nearby_events`, and communities listings — but `public_profiles` direct-lookup has no blocked-pair filter either, and a blocked user's full public profile stays readable by id.
**Decision:** T18's write list gains `public_profiles`: add the same both-directions `NOT EXISTS (SELECT 1 FROM blocks …)` predicate, plus the hostile assertions the audit named (a blocked pair sees neither the other's `public_profiles` row nor `attendee_previews` row, bidirectionally). This stays a **Phase 2** task (T18) — it must land before any build ships (it's a non-negotiable guard). Direct navigation to a blocked user's profile being blocked is confirmed in-scope for the guard.
**Rationale:** The guard says "invisible in every list, feed, attendee view, and channel." A direct id lookup of a full public profile is a monitoring surface; excluding it costs one predicate and closes the guard consistently.
**Impact:** Phase 2 T18 write-list + hostile suite; no Phase 3 change.

## D14 — Edge envelope: keep kill-switch-first, but gate the DB read behind cheap JWT verify
**Date:** 2026-07-17
**Context:** Phase 2 audit F5. Artifact B's envelope specifies "kill switch first — the only pre-auth DB touch." That makes the `feature_flags` service-role SELECT run before JWT verify, so an anon-key holder (valid gateway JWT, `role≠authenticated`) drives one unthrottled DB read per request before the 401.
**Decision:** Amend the envelope order to: (1) parse+verify JWT (CPU-only HMAC, no DB) and reject tokenless/invalid with 401 **before** any DB touch; (2) kill-switch `feature_flags` read on the now-authenticated path; (3) rate limit; (4) effect; (5) audit. The kill switch remains the only pre-**effect** DB touch, and audit is still gated on `callerId!=null`. This preserves every existing guarantee (T7b.1 anti-flood, kill-switch semantics) while removing the anonymous DB-read amplification vector. Requires updating Artifact B's envelope wording and the `_shared/envelope.ts` order.
**Rationale:** JWT verify is free (no DB); doing it first is strictly better for the anonymous-abuse case with no downside. The original "kill switch first" was to guarantee a disabled function does nothing — still true, since an unauthenticated caller has nothing to disable *for*, and an authenticated caller still hits the kill switch before any effect.
**Impact:** Folded into the Phase 3 hardening migration/functions pass (T23); Artifact B §envelope amended; hostile suite gains the F9/F16 assertions.

## D15 — T18 block-invisibility mechanism: inlined predicate in DEFINER objects; nearby_events INVOKER→DEFINER; communities deferred
**Date:** 2026-07-17
**Context:** Implementing T18 (migration 0005). The `blocks` RLS policy `blocks_select_own` (0001) exposes to a client only rows where the caller is the *blocker* — so any INVOKER read path (RPC or base-table RLS policy) can enforce only the "I blocked them" direction and is structurally blind to "they blocked me". Bidirectional invisibility is a non-negotiable guard.
**Decision:**
1. **Inline a bidirectional `not exists (… public.blocks …)` predicate directly inside the DEFINER objects** `public_profiles`, `attendee_previews`, and `nearby_events`. Table access inside a definer object uses the OWNER's privileges (postgres, not subject to the client `blocks` RLS), so the subquery sees both rows and enforces both directions. The block rows are never emitted — only filtered results — so the manage_block "target cannot detect the block" invariant holds.
2. **A shared `SECURITY DEFINER` helper was tried and rejected:** a view checks function EXECUTE against the *invoking* role (empirically — `permission denied for function` when `authenticated` selected the view), so the helper would have to be granted to clients, turning it into a "did X block me?" probe. Inlining avoids the grant entirely.
3. **`nearby_events` INVOKER→DEFINER.** Required so its inlined subquery sees both block rows. The visible row-set is provably unchanged by the mode switch: the function already returned `status='published'` only (now a LOAD-BEARING filter, since RLS no longer backs it) and all spaces are readable by every authenticated user (`spaces_select_authenticated USING(true)`). Only the block exclusion is added. `nearby_spaces` stays INVOKER (venues have no block dimension — a public place isn't hidden by blocking its claimed owner, per D8). Supersedes the audit's "nearby_* are INVOKER" clean-class note for `nearby_events` specifically.
4. **Communities deferred to Phase 3 (T26).** The only Phase 2 community read (`communitiesMeetingAt`, Space Detail) is a base-table RLS read with no definer path; a correct bidirectional filter needs one, and community discovery/listing is a Phase 3 feature. T26 adds the block filter when community reads consolidate. Logged so it isn't lost.
**Rationale:** Inlining is the minimal, non-leaking way to get owner-privilege access to `blocks` from a read path. The DEFINER switch on `nearby_events` is safe because published-only + public-spaces already fully determined its visible set.
**Impact:** Migration 0005 (T18); hostile suite gains bidirectional assertions (both A-as-blocker and A-as-blocked directions, plus a reverse-viewer section proving the definer read, not caller RLS, drives exclusion) — verified green. Phase 3 plan T26 gains the community block filter. Phase 2 audit F1/F1b closed at the data layer.
**Date:** 2026-07-13
**Context:** Loop 5, Q1 from T11. T7a shipped `ReportReason`/`ReportSubjectType` wire enums inside `Features/Profile/EdgeFunctionClient.swift` (Models/ didn't exist yet); T11's canonical `Models/Report.swift` enums collide with them.
**Decision:** Option (a). `Models/` is the single source of truth for entity and enum shape — one Swift enum per SQL type, named after the SQL type (`ReportReason`, `ReportSubject`, `ReportStatus`…). T7a's duplicates are deleted; presentation concerns (`label`, `Identifiable` for pickers) move to an `extension ReportReason` in the Profile feature layer. T11's write list is expanded accordingly (`EdgeFunctionClient.swift`, `ReportSheetView.swift`, `ProfileTests.swift` — mechanical repoint only). Standing rule for all future tasks: a feature needing UI affordances on a model enum writes an extension in its own folder; it never redeclares the type.
**Rationale:** Two enums modeling one SQL type at a moderation wire boundary is silent-drift waiting to happen (a new reason added to one side passes both tests and desyncs the wire). (b) would make Models depend on a feature folder — layering inversion. (c) avoids touching T7a but institutionalizes the duplication. The plan's contract ("Models/ replaces all mocks") intends exactly (a).
**Impact:** T11 write-list expansion (logged in phase-2.md); T13/T15/T18 consume Models enums only; CLAUDE.md-worthy pattern at next Loop 4.
