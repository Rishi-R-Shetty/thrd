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

## D10 — Models/ owns the canonical enums for every SQL type; features extend, never redeclare
**Date:** 2026-07-13
**Context:** Loop 5, Q1 from T11. T7a shipped `ReportReason`/`ReportSubjectType` wire enums inside `Features/Profile/EdgeFunctionClient.swift` (Models/ didn't exist yet); T11's canonical `Models/Report.swift` enums collide with them.
**Decision:** Option (a). `Models/` is the single source of truth for entity and enum shape — one Swift enum per SQL type, named after the SQL type (`ReportReason`, `ReportSubject`, `ReportStatus`…). T7a's duplicates are deleted; presentation concerns (`label`, `Identifiable` for pickers) move to an `extension ReportReason` in the Profile feature layer. T11's write list is expanded accordingly (`EdgeFunctionClient.swift`, `ReportSheetView.swift`, `ProfileTests.swift` — mechanical repoint only). Standing rule for all future tasks: a feature needing UI affordances on a model enum writes an extension in its own folder; it never redeclares the type.
**Rationale:** Two enums modeling one SQL type at a moderation wire boundary is silent-drift waiting to happen (a new reason added to one side passes both tests and desyncs the wire). (b) would make Models depend on a feature folder — layering inversion. (c) avoids touching T7a but institutionalizes the duplication. The plan's contract ("Models/ replaces all mocks") intends exactly (a).
**Impact:** T11 write-list expansion (logged in phase-2.md); T13/T15/T18 consume Models enums only; CLAUDE.md-worthy pattern at next Loop 4.
