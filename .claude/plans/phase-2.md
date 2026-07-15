# Phase 2 Plan — Discovery & Maps (Weeks 4–7)

**Status:** APPROVED — 2026-07-13 by user. Loop 2 active: T11 → Sonnet, T12 → orchestrator.
**Sources:** PRD §4 Phase 2 + §2 entities · threat-model.md §5 Phase 2 must-haves · app-store-plan.md (§3 privacy manifests, §5.1.5 location) · Artifact A PLANNED policies · Artifact B stubs · Phase 1 completion notes · decisions D6–D9 (two-city defaults, OSM sourcing, coarsening semantics, device-local emergency contact).
**Precondition met:** TD4 light-mode terracotta landed (`bdfaa78`) before any Phase 2 build, per user instruction.

## Exit criteria (verbatim from PRD)

> **Exit criteria:** a user can find a real event nearby and RSVP.

Plus the Phase 2 must-haves pinned by the threat model (§5): coarsened location queries (D8 semantics), blocked-user invisibility, first-meeting safety sheet, panic button.

## Two-city amendments (user directive, D6/D7)

- Launch cities: **Bengaluru + Mumbai**. Discover defaults to the nearest city (last coarse location → locale → Bengaluru).
- Seed pipeline targets **100–200 spaces per city**, sourced from **OSM/Overpass** (Google Places prohibited for stored data — ToS; D7). ODbL attribution ships in the About screen.
- Nothing else in the PRD scope changes; ranking, screens, and RSVP are city-agnostic.

## Hard prerequisite (user, carried from Phase 1)

Hosted deploy: `supabase link` + `db push` (0001+0002, then Phase 2's 0003/0004), `functions deploy` + `THRD_JWT_SECRET`, at least one auth provider. **T13 onward cannot exit against an empty hosted project.** The seed pipeline (T20) also needs the hosted DB reachable with the service-role key kept local-only.

## Data-shape contract (fully realized — Models/ replaces all mocks)

Swift models in `Models/` mirror migration 0001 **byte-for-byte** (snake_case ↔ camelCase via CodingKeys). Enums mirror the SQL enums exactly. Any deviation is a fix task.

**Space** — `id: UUID` · `ownerUserId: UUID?` · `name: String` · `category: SpaceCategory (cafe|park|studio|venue|other)` · `latitude/longitude: Double` (decoded from RPC DTOs — the raw PostGIS `location` column is never decoded client-side) · `address: String` · `photos: [String]` · `amenities: [String]` · `hours: JSONValue?` · `capacity: Int?` · `isPartner: Bool` · `ratingAgg: Decimal?` · `createdAt: Date`. New column (T12, admin-only): `source_ref text` — seed provenance (`osm:node/…`), zero client grants.

**Event** — `id: UUID` · `communityId: UUID?` · `hostId: UUID` · `spaceId: UUID` · `title: String` · `description: String?` · `coverUrl: String?` · `startsAt/endsAt: Date` · `recurrenceRule: String?` · `capacity: Int?` · `price: Int` (minor units, 0 = free) · `status: EventStatus (draft|published|cancelled|completed)` · `rsvpCount: Int` · `createdAt: Date`.

**Community / CommunityMembership / Ticket / Report** — per migration 0001, decoded but with **no Phase 2 write paths** except Ticket via `rsvp_event` (Community UI is Phase 3; Report/Block already live via T7a).

**Discovery DTOs (new, RPC-returned — distance is computed, never an entity field):**
- `NearbySpace` = Space fields + `distanceMeters: Int` + `upcomingEventCount: Int`.
- `NearbyEvent` = Event fields + venue name/lat/lng + `distanceMeters: Int`.
- RPCs (T12): `nearby_spaces(cell text, radius_m int)` / `nearby_events(cell text, radius_m int, starts_within interval)` — `cell` is a **geohash-5 cell id**, snapped client-side AND re-snapped server-side (D8); raw coordinates are rejected, never logged. Results ordered by distance; radius capped server-side (≤10km).
- `attendee_previews` view: `event_id, display_name (first word), avatar_url` for `going` tickets on **published** events only — the PRD's "attendee avatars" social proof under the attendee-list-privacy guard (no handles, no last names); blocked pairs excluded (T18).

**`rsvp_event` wire contract (Artifact B addition, spec'd in T12 before T16 builds):**
Request `{ "event_id": uuid, "action": "rsvp" | "cancel" }` — identity from JWT only. 200: `{ "status": "going" | "waitlist" | "cancelled", "rsvp_count": int }`. Capacity decided **inside the function's transaction** (never client counts); waitlist promotion on cancel is transactional too. Errors: standard envelope + `event_not_open` (draft/cancelled/completed/past), `not_found`. Rate: 30/user/hour, 60/IP/hour. Tier-0 cap (threat-model Layer 3): free public events with capacity ≤ 20 only until phone verification — enforced in-function from `verification_status`.

**LaunchCity (client, D6)** — `enum LaunchCity { bengaluru, mumbai }` with `center`, `geohash5`, `nearest(to:)`. Replaces T9's single `defaultCity` constant.

## Ordered task list

Dependency chain: {T11 ∥ T12} → T13 → {T14 ∥ T15} → T16 (needs T12 only) → T17 → T18 → T19 → T21. T20 needs T12 + hosted deploy and can run any time after. A2-style review gate on T16 (orchestrator reviews against Artifact B before merge).

---

### T11 — Models/: real entities + decoding tests — **Sonnet**
- **Reads:** migration 0001, PRD §2, plan contract above.
- **Writes:** `Models/{Space,Event,Community,CommunityMembership,Ticket,Report}.swift`, `thrdspacesTests/ModelsTests.swift` (JSON fixtures round-trip every field; enum raw values asserted against the SQL enum lists verbatim).
- **Exit:** build + tests green; every field/CodingKey matches the migration column list byte-for-byte (test-enforced, not eyeballed).

### T12 — Geo read layer: migration 0003 + Artifact A/B updates — **Orchestrator (Fable)**
- **Reads:** Artifact A PLANNED sections, threat-model Layers 4/7, D6–D8.
- **Writes:** `supabase/migrations/0003_geo_reads.sql` — `nearby_spaces`/`nearby_events` RPCs (SECURITY DEFINER, snapped-cell input per D8, radius cap, distance via `ST_Distance`), `attendee_previews` view, `spaces.source_ref` (zero client grants), `events_select_own_drafts` policy, `profile_visibility` UPDATE grant, supporting indexes; hostile-suite additions (RPC re-snaps/rejects raw coords · drafts visible to host only · attendee_previews leaks no handles/private profiles · source_ref unreadable by clients); `docs/security/rls-policies.sql` PLANNED→MIGRATED moves; `docs/security/edge-functions.md` gains the full `rsvp_event` + `purge_deleted_accounts` specs (T16 builds only from this spec).
- **Exit:** fresh local stack: migration applies; extended hostile suite green; RPC returns correct distances for a two-city fixture; zero tables/views without RLS or explicit access design.

### T13 — SupabaseDiscoverRepository behind the T9 protocol — **Opus**
- **Reads:** T11/T12 outputs, T9's `DiscoverRepository` protocol.
- **Writes:** `Features/Discover/DiscoverRepository.swift` (protocol re-shaped to return `NearbySpace`/`NearbyEvent`; mock updated to the same shapes — kept for previews/tests), new `Features/Discover/SupabaseDiscoverRepository.swift` (calls the RPCs; client-side geohash-5 snap of the user cell via `LocationManager.geohash` BEFORE any request — D8), deletes Discover's local mock entity types in favor of `Models/`.
- **Exit:** integration test against local stack returns seeded fixtures with distances; unit test asserts an unsnapped coordinate can never reach the transport (the request builder only accepts a `Geohash5` value type); mock and live conform to one protocol.

### T14 — Map + clustering + ranked list + two-city defaults — **Opus**
- **Reads:** T13, PRD §3 Tab 1, D6.
- **Writes:** `Features/Discover/DiscoverView.swift`, `DiscoverViewModel.swift` (LaunchCity resolver replaces `defaultCity`; pill filters Today · This Week · Free · category chips), `SpaceClusterAnnotation.swift` (MapKit clustering), list toggle with ranking = `distanceMeters` ascending weighted by interest-tag overlap with `users.interests` (simple heuristic per PRD — document the formula in-code for Phase 4's ranking replacement).
- **Exit:** sim: map renders seeded two-city data, clusters at low zoom; list ranks a nearer-but-no-overlap space below a slightly-farther 3-tag-overlap space (test with fixtures); location-denied state still works; TD4-dark note honored if this task touches button styles.

### T15 — Space Detail + Event Detail — **Opus**
- **Reads:** T13, PRD §3 detail screens, T7a review note (re-mount Report/Block).
- **Writes:** `Features/Discover/SpaceDetailView.swift` (photos, hours, communities-that-meet-here list from public communities, upcoming events), `EventDetailView.swift` (host public profile w/ ⋯ Report/Block re-mounted, venue map snippet, `attendee_previews` avatars, RSVP CTA placeholder wired in T17), view models.
- **Exit:** both screens render seeded data in sim; attendee previews show first-names/avatars only; Report/Block reachable in ≤2 taps from a host profile; every image has alt text or `accessibilityHidden`.

### T16 — `rsvp_event` Edge Function + `purge_deleted_accounts` cron — **Opus, separate delegation; A2 review gate**
- **Reads:** Artifact B specs from T12 ONLY, `_shared/` envelope (T7b), migration 0003.
- **Writes:** `supabase/functions/rsvp_event/`, `supabase/migrations/0004_rsvp_support.sql` (service_role column-scoped grants for tickets/events.rsvp_count per D5 pattern; pg_cron schedule for `purge_deleted_accounts`), `supabase/functions/purge_deleted_accounts/` (30-day hard-delete per Artifact B §1), hostile/behavior test script additions (capacity race: two concurrent RSVPs on last seat → exactly one `going` one `waitlist`; tier-0 cap enforced; cancel promotes waitlist head; purge re-keys audit rows).
- **Review gate:** orchestrator line-by-line vs Artifact B before merge. No approve-with-comments.
- **Exit:** local stack: full curl matrix green including the concurrency test; envelope order/audit/kill-switch identical to T7b functions.

### T17 — RSVP UI end-to-end — **Opus**
- **Reads:** T15/T16, T9's RSVP console-print ponytail.
- **Writes:** `Features/Profile/EdgeFunctionClient.swift` (adds `rsvp(eventID:action:)` — body carries event id + action only), `EventDetailView`/view model (CTA states: RSVP → Going / Waitlisted / Cancel, optimistic count with server reconcile), own-tickets read in `Features/Discover/` ("your spot" state on cards).
- **Exit:** sim against local stack: RSVP → ticket row visible to self; second account fills capacity → waitlist state renders; cancel promotes; T9's console print replaced by the real call; 429/`event_not_open` surfaced with non-leaking copy.

### T18 — Blocked-user invisibility across every Phase 2 read path — **Orchestrator (SQL) + Opus (client sweep)**
- **Reads:** blocks table, all T12 views/RPCs, threat-model Layer 7.
- **Writes:** `supabase/migrations/0005_block_invisibility.sql` — blocked-pair exclusion (both directions) in `public_profiles`, `attendee_previews`, `nearby_events` (events hosted by a blocked/blocking user vanish), communities listings; hostile tests: after B blocks A, A sees neither B's profile, nor B's attendance, nor B-hosted events — and symmetrically; client sweep task confirms no screen caches a pre-block row.
- **Exit:** hostile suite green with the bidirectional assertions; sim demo: block a host → their event disappears from Discover on next load.

### T19 — Safety surfaces: first-meeting sheet + panic button — **Opus**
- **Reads:** threat-model Layer 7, app-store-plan §1.4.1, D9.
- **Writes:** `Features/Safety/FirstMeetingSafetySheet.swift` (non-dismissable checkbox flow before the FIRST RSVP with a new host/community — trigger state derived server-side from own tickets, not UserDefaults), `Features/Safety/PanicButton.swift` (on EventDetail within −2h/+2h of start: one-tap dial local emergency number + prefilled SMS to the Keychain-resident emergency contact with a maps link — D9), `Features/Safety/EmergencyContactView.swift` (setup in Settings + safety sheet; Keychain only), tests for the trigger windows.
- **Exit:** sheet blocks the first-RSVP path until acknowledged (test); panic button visible only inside the window (test); emergency contact grep: nowhere in any network call or table write; Review-Notes copy drafted for app-store-plan §6.

### T20 — Seed pipeline: OSM → two cities — **Sonnet**
- **Reads:** D6/D7, migration 0003 (`source_ref`), spaces schema.
- **Writes:** `scripts/seed/` (Overpass queries per city for cafe/park/studio/venue tag sets, category mapping, validation — name/address/coord sanity, dedupe on `source_ref`, ~100–200 per city curated by rating/completeness heuristics), runs with `SUPABASE_SERVICE_ROLE_KEY` from local env ONLY (never committed — script refuses to run if the key appears in a file), `docs/compliance/attribution.md` (ODbL), small client task: OSM attribution line in Settings→About.
- **Exit:** hosted DB holds 100–200 validated spaces per city, re-run is idempotent (0 duplicates); attribution visible in-app; grep proves no key material in the repo.

### T21 — Phase exit verification — **Orchestrator (Fable)**
- **Exit:** PRD criterion demonstrated end-to-end on device with seeded data (find a real event nearby → RSVP → ticket exists); full hostile suite green; `service_role` greps clean; threat-model §5 Phase 2 items all shipped; completion notes + CLAUDE.md learnings + Phase 3 draft; stop for user review.

---

## Non-negotiable guards active this phase

D8 coarsening: user coordinates never leave the device unsnapped; RPCs re-snap server-side · venue pins exact (public places) · capacity/waitlist decided only inside `rsvp_event`'s transaction · blocked users invisible in every list/feed/attendee view, hostile-tested bidirectionally (T18) · attendee previews: first name + avatar only · emergency contact device-local only (D9) · seed service-role key never enters the repo (T20) · tier-0 RSVP cap ≤ capacity-20 events until phone verification · accessibility labels everywhere · RLS default-deny on every new view/RPC path.

## Risks / notes for the user

1. Everything from T13 on needs the **hosted deploy** (Phase 1 user actions) — that's now the phase's critical path.
2. Overpass API is rate-limited/flaky; T20 may need a mirror or retry budget. If OSM coverage for a category is thin in either city, the fix is widening tag sets, not switching to Google (D7).
3. `attendee_previews` deliberately shows social proof to any signed-in user (PRD) — flag if you want it gated to RSVPed users instead.
4. TD4 residual (dark-mode terracotta) will ride along with the first UI task that touches buttons (likely T14/T15).

## Task approval log

*(Loop 3 appends one line per approved task here.)*

- **T11 — Loop 5 note** (2026-07-13): Q1 (report-enum ownership collision with T7a) resolved as D10 — Models/ canonical, feature-layer extensions for UI affordances. T11's write list expanded to include the mechanical repoint of `EdgeFunctionClient.swift`, `ReportSheetView.swift`, `ProfileTests.swift`.
- **T11 — APPROVED** (2026-07-13, commit `bb1a0c3`). Seven Models files, 63/63 tests, enum parity independently spot-verified against migration labels, D10 repoint mechanical (ProfileTests passed unmodified), mock rename exact. T13 note: `NearbySpace` DTO carries lat/lng non-optional; don't let `Space`'s optionality smear into UI.
- **T13 — APPROVED** (2026-07-14, commit `e489c5d`; agent's code, orchestrator-run verification + commit after a session-limit death at the commit step). Geohash5 compile-time D8 boundary + XCTest-aware tripwire; integration tests ran live (Bengaluru returned, Mumbai excluded, server cell-guard proven independently of the client type); local demo anon key accepted as a documented non-secret. Note for future: PostgrestError→400 mapping is RPC-specific.
- **T14 — APPROVED** (2026-07-14, commit `13175cd`). UIKit clustering with documented displayPriority fix; TD1 a11y preserved (counted cluster announcements); D6 resolver test-pinned; ranking scorer Phase-4-ready; filter split (category→spaces, time/price→events) accepted as canonical. Visual on-device pass deferred to T21/post-deploy (app targets hosted project).
- **T14 — APPROVED** (2026-07-14, commit `13175cd`). Native MapKit clustering via UIViewRepresentable (SwiftUI Map has no clustering API), TD1 a11y preserved in the UIKit marker, clusters announce counts, VM flipped to live repository, D6 LaunchCity resolver, 83/83. One low-freq map-sync edge → TD6 (deferred). Ranking is distance-only with an overlap-ready scorer (Phase 4 upgrade).
- **T15 — APPROVED w/ fix T15.1** (2026-07-14, commit `cb560ae` + fix pending). Detail screens, explicit column lists on every query (verified), attendee first-name-only proven on the wire, Report/Block re-mounted on host, 93/93. Fix T15.1 applied and verified (commit `7e255e0`, 95/95): per-section error flags, each fetch in its own do/catch, concurrent start preserved — a partial failure no longer masks the loaded section. One reviewer finding refuted (duplicate-pin: nearby_spaces RPC is one-row-per-space, no fan-out).
- **T16 — APPROVED** (2026-07-14, commit `251fade`, A2 gate passed). Line-by-line vs Artifact B §4/§5 + independent verification: hostile suite green on clean 0001–0004 (audit-immutability exception holds — service_role UPDATE on audit_log still denied; RPC/purge not client-callable); purge happy-path verified directly as owner (P deleted, survivor untouched, audit re-keyed to null+hash). Event-row FOR UPDATE serializes the capacity race; tier-0 cap server-read; purge is a postgres-owned SECURITY DEFINER SQL function (no HTTP caller). One Phase-3 landmine logged as D11 (purge fail-closes on host/creator users — unreachable in Phase 2). Backend-only; no iOS build run (correct).
- **T12 — COMPLETE** (2026-07-13, orchestrator). Migration 0003 applies on a fresh stack (0001→0003); extended hostile suite green — new assertions: geohash-5-only RPC boundary (6-char and raw-coord inputs rejected), Mumbai excluded from a Bengaluru cell at the 10km cap, `source_ref` unreadable (42501), own-drafts visible / foreign drafts not, attendee_previews first-name+avatar-only with no handle column, anon denied on the RPCs. One Phase-1 assertion updated by design (foreign-draft invariant). One fix during verification: `assert_geohash5` needed authenticated EXECUTE under SECURITY INVOKER. Artifact A PLANNED→MIGRATED; Artifact B gained full `rsvp_event` + `purge_deleted_accounts` specs (T16 builds only from these).
