# Phase 1 Plan — Core Setup & Auth (Weeks 1–3)

**Status:** APPROVED — 2026-07-11, with three user amendments (A1–A3), incorporated below. D1 confirmed by user: T6/T7 stay in Phase 1. Loop 2 active.

**User amendments at approval:**
- **A1:** T6 `age_attestation` audit entry gets a mandatory metadata shape (see T6 contract).
- **A2:** T7 split into T7a (SwiftUI, Opus) and T7b (Edge Functions, Opus, separate delegation; orchestrator reviews T7b against Artifact B before merge). Dependency chain updated.
- **A3:** support email is a `Configuration.plist` value, not a hardcoded string in `SettingsView.swift`.
**Sources:** PRD §4 Phase 1 + §5 folder structure · threat-model.md §5 Phase 1 must-haves · app-store-plan.md §1 Phase 1 compliance features · decisions D1–D3.

## Exit criteria (verbatim from PRD)

> **Exit criteria:** a user can sign up, set interests, and see an empty Discover shell.

Plus the Phase 1 must-haves the other ground-truth docs pin to this phase (see D1):

- Sign in with Apple + phone OTP, RLS on all tables, Keychain for tokens, no secrets in bundle, basic report flow, age gate. (threat-model.md §5)
- Report, block, EULA-accept in-build; in-app account deletion; Declared Age Range API in auth/onboarding. (app-store-plan.md §§1, 4)

## Current repo state

- `thrdspaces/` Xcode project: default scaffold (`thrdspacesApp.swift`, `ContentView.swift`), mock `DiscoverView.swift` inside the target, and a **diverging second copy** at `thrdspaces/Features/Discover/DiscoverView.swift` outside the target. T1 resolves the duplication (target copy wins; the stranded copy is deleted).
- No Supabase project linked yet. No `supabase/` directory. **User prerequisite: create the Supabase project and hand the URL + anon key to the orchestrator before T4 starts** (anon key only — service-role key never enters this repo or the app bundle).
- Project/target name is `thrdspaces` (PRD diagrams say `ThrdSpaces/`). Keeping the existing name; renaming an Xcode project is pure churn. Folder layout below is inside the existing target.

## Target folder layout (end of Phase 1)

```
thrdspaces/thrdspaces/
├── App/                    thrdspacesApp.swift, RootTabView.swift
├── Core/
│   ├── DesignSystem/       Theme.swift, ThrdButton.swift, ThrdCard.swift, ChipGroup.swift
│   ├── Networking/         SupabaseClientProvider.swift, APIError.swift
│   ├── Security/           KeychainTokenStore.swift
│   ├── Location/           LocationManager.swift
│   └── Extensions/
├── Models/                 User.swift, Space.swift, Event.swift, Community.swift, Ticket.swift, Report.swift, InterestTag.swift
├── Features/
│   ├── Onboarding/         WelcomeCarouselView, SignInView, AgeGateView, EULAView, InterestPickerView, LocationPrimerView, OnboardingCoordinator
│   ├── Discover/           DiscoverView.swift (existing mock, relocated)
│   ├── Communities/        CommunitiesPlaceholderView.swift
│   ├── Create/             CreatePlaceholderView.swift
│   ├── Messages/           MessagesPlaceholderView.swift
│   └── Profile/            ProfileView, ProfileEditView, SettingsView, AccountDeletionView, BlockedUsersView, ReportSheetView, ProfileViewModel
└── Resources/              Assets.xcassets
supabase/
├── migrations/0001_initial_schema.sql
└── tests/rls_hostile_user_tests.sql
docs/security/rls-policies.sql          (Artifact A)
docs/security/edge-functions.md         (Artifact B, Phase-1 slice)
```

## Data-shape contract

All field names/types below are canonical for Phase 1. Swift models, the SQL migration, and every view model use exactly these names (snake_case in SQL, camelCase in Swift via `CodingKeys`). Any deviation is a fix task, not a review comment.

**User** — `id: UUID` · `handle: String` (unique, 3–30 chars, `[a-z0-9_]`) · `display_name: String` · `avatar_url: String?` (nullable; **no write path in Phase 1**, D2) · `bio: String?` (≤280) · `interests: [String]` (tag ids from the fixed Phase-1 tag list) · `home_geohash: String?` (precision 5, ~2km — never finer) · `verification_status: enum none|phone|id_verified` · `trust_score: Int` (server-derived, client read-only) · `created_at: Date`

**InterestTag** — fixed client-side list of 12 per PRD §3: `books, running, chess, coffee, music, wellness, art, food, sport, tech, language, board_games`. `id: String` (the slug) · `label: String` · `sfSymbol: String`. No DB table in Phase 1; `users.interests` stores slugs.

**Space / Event / Community / CommunityMembership / Ticket** — schema per PRD §2 verbatim (T3 migrates all of them so RLS lands table-by-table from day one), but **no Phase 1 UI reads or writes them**. Discover shell renders mock data only.

**Report** — `id: UUID` · `reporter_id: UUID` (server-derived from JWT, never client-supplied) · `subject_type: enum user|event|community|message` · `subject_id: UUID` · `reason: enum safety|harassment|spam|other` + `detail: String?` (≤500) · `status: enum open|reviewed|actioned` · `created_at`. Phase 1 UI exposes only `subject_type = user`.

**Block** — not in the PRD entity list but required by compliance Phase 1: `blocker_id: UUID` · `blocked_id: UUID` · `created_at`. Composite PK. Enforcement across feeds/lists is Phase 2; Phase 1 ships the table, RLS, and the block/unblock UI on profiles.

**Auth session** — access token (1h) + refresh token (30d) from Supabase Auth. Stored **only** in `KeychainTokenStore` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Device fingerprint: generated UUID, Keychain-resident.

**Audit log** — insert-only `audit_log`: `id` · `user_id` · `action: String` (Phase-1 actions: `signup`, `login`, `age_attestation`, `eula_accept`, `report_submit`, `block`, `account_delete_request`) · `metadata: jsonb` · `created_at`. No client SELECT policy at all.

## Ordered task list

Dependency chain: T1 → T2 → {T3 ∥ T8} → T4 → T5 → T6 → T7a → T9 → T10. T7b depends only on T3 (Artifact B spec) and can run in parallel with T4–T6, but must pass the orchestrator's line-by-line review against Artifact B and merge **before** T7a's exit tests run (T7a calls the deployed functions). T3 is orchestrator work and can start immediately after T1 lands.

---

### T1 — Project restructure & 5-tab shell — **Sonnet**
- **Reads:** entire `thrdspaces/` tree, PRD §5.
- **Writes:** `thrdspaces.xcodeproj/project.pbxproj`; creates the folder layout above; moves `thrdspacesApp.swift` → `App/`; new `App/RootTabView.swift` (5 tabs: Discover · Communities · ➕ Create · Messages · Profile); relocates the in-target `DiscoverView.swift` → `Features/Discover/`; **deletes** the stale out-of-target `Features/Discover/DiscoverView.swift` and `ContentView.swift`; placeholder views for the 4 non-Discover tabs.
- **Contract:** none (no entities).
- **Exit:** app builds and runs in simulator; all 5 tabs render; Discover tab shows the existing mock map/bottom-sheet UI; every tab item has an accessibility label.

### T2 — Design system — **Opus**
- **Reads:** `Features/Discover/DiscoverView.swift` (embedded `Theme` enum), PRD §3.
- **Writes:** `Core/DesignSystem/Theme.swift` (colors incl. dark-mode variants, typography with Dynamic Type, spacing tokens, radii), `ThrdButton.swift`, `ThrdCard.swift`, `ChipGroup.swift` (multi-select, used by interest picker); edits `DiscoverView.swift` only to delete its embedded `Theme` and point at the shared one.
- **Contract:** `ChipGroup` binds to `Set<String>` of `InterestTag.id`.
- **Exit:** SwiftUI previews for all four components in light/dark at XL Dynamic Type; every interactive element has an accessibility label/trait; DiscoverView still renders identically.

### T3 — RLS policy spec + initial schema migration — **Orchestrator (Fable)** — schema/architecture stays with me per CLAUDE.md
- **Reads:** PRD §2, threat-model.md Layers 4–5 and §4.
- **Writes:** `docs/security/rls-policies.sql` (Artifact A: every table, every policy, hostile-user assertions), `supabase/migrations/0001_initial_schema.sql` (users, spaces, communities, community_memberships, events, tickets, reports, blocks, audit_log — RLS enabled default-deny on **every** table in the same migration, `public_profiles` view for cross-user reads), `supabase/tests/rls_hostile_user_tests.sql` (user A cannot read/write user B's rows, per table), `docs/security/edge-functions.md` (Artifact B, Phase-1 slice: `delete_account` purge with 30-day grace, `submit_report` with rate limit + dedupe — each with JWT verification, rate limit, audit write, non-leaking errors).
- **Contract:** authoritative source for the data-shape contract above; `trust_score`, `verification_status`, `reporter_id` are server-derived — no client write policy exists for them.
- **Exit:** migration applies cleanly to a fresh local Supabase; all hostile-user tests pass; zero tables with RLS disabled (`select relname from pg_class ... where not relrowsecurity` returns nothing).

### T4 — Keychain token store + Supabase client core — **Opus**
- **Reads:** threat-model.md Layers 1–2; Supabase Swift SDK docs.
- **Writes:** `Core/Security/KeychainTokenStore.swift`, `Core/Networking/SupabaseClientProvider.swift`, `Core/Networking/APIError.swift`; adds `supabase-swift` SPM package; `Configuration.plist` entry for Supabase **URL + anon key only** (URL and anon key are public by design; still never the service-role key, which must not exist anywhere in this repo).
- **Contract:** Auth session shape above; `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on every Keychain item; device-fingerprint UUID created on first launch.
- **Exit:** unit tests prove tokens round-trip through Keychain and are absent from UserDefaults/files; client boots against the Supabase project; a grep of the built product for `service_role` finds nothing.

### T5 — Auth: Sign in with Apple + phone OTP — **Opus**
- **Reads:** T4 outputs, threat-model.md Layer 2, app-store-plan.md Guideline 4.8.
- **Writes:** `Features/Onboarding/SignInView.swift`, `AuthRepository.swift`, `AuthViewModel.swift`; Signing & Capabilities (Sign in with Apple entitlement).
- **Contract:** on first successful auth, creates the `users` row (`id` from `auth.uid()`, placeholder handle pending T6/T7); nonce included in the SwA request and verified by Supabase Auth server-side; OTP rate limits are Supabase-side (3/phone/hr, 10/IP/hr) — client shows the error state, never implements its own bypass.
- **Exit:** on device, both SwA and phone OTP produce a session; tokens land in Keychain only; kill+relaunch restores the session; sign-out wipes Keychain.

### T6 — Onboarding flow: carousel, age gate, EULA, interest picker, location primer — **Opus**
- **Reads:** T2/T5 outputs, PRD §3 onboarding, app-store-plan.md §§1.2, 4, D3.
- **Writes:** `Features/Onboarding/`: `WelcomeCarouselView.swift` (3 screens, skippable), `AgeGateView.swift` (Declared Age Range API → under-18 blocks creation with explainer; unavailable → 18+ self-attestation per D3, logged to `audit_log`, age result never persisted), `EULAView.swift` (scrollable ToS, explicit accept before account activation, logged), `InterestPickerView.swift` (ChipGroup, 12 tags, ≥3 enforced, writes `users.interests`), `LocationPrimerView.swift` (value-first screen — "Find spaces within walking distance" — **before** the system prompt), `OnboardingCoordinator.swift` (state machine: welcome → sign-in → age gate → EULA → interests → location → Discover).
- **Contract:** `users.interests: [String]` of tag slugs; `audit_log` actions `age_attestation`, `eula_accept`. **(A1)** The `age_attestation` entry's `metadata` jsonb is exactly `{ device_id: String (Keychain device-fingerprint UUID from T4), method: "api" | "attestation", api_result: String? }` — `api_result` carries the raw age-range category when `method = "api"`, null otherwise. This is the gate *result* trail, not persisted age data; it stays consistent with D3's ephemerality rule.
- **Exit:** fresh install walks the full flow and lands on Discover; under-18 API result blocks signup; interests persist to Supabase and survive relaunch; "Continue" disabled below 3 interests; all screens VoiceOver-navigable.

### T7a — Profile UI: create/edit, settings, account deletion, block & report — **Opus** *(A2)*
- **Reads:** T3 contract, T5/T6 outputs, T7b's deployed function signatures, app-store-plan.md §§1.2, 5.1.1(v), D1, D2.
- **Writes:** `Features/Profile/`: `ProfileView.swift` (initials avatar per D2 — **no image picker anywhere**), `ProfileEditView.swift` (handle w/ uniqueness check, display_name, bio, interests re-pick), `SettingsView.swift` (Terms of Use, contact email, blocked users, delete account), `AccountDeletionView.swift` (two-step confirmation, "what gets deleted" copy, calls `delete_account` Edge Function), `BlockedUsersView.swift`, `ReportSheetView.swift` (reusable; Phase 1 mounts it on profiles via ⋯ menu, reason enum + optional detail, calls `submit_report`), `ProfileViewModel.swift`; adds `SupportEmail` key to `Configuration.plist` (created in T4). **(A3)** `SettingsView` reads the contact email from `Configuration.plist` — no hardcoded email string anywhere in Swift source.
- **Contract:** User editable fields = `handle, display_name, bio, interests` only; `blocker_id` derived server-side from JWT; support email = `Configuration.plist:SupportEmail`.
- **Exit:** edit → relaunch → persisted; second account cannot take an existing handle; block/unblock round-trips; report lands in `reports` with correct `reporter_id`; delete account signs out and the grace-period row state is verifiable in Supabase; ⋯ → Report and Block reachable on any profile in ≤2 taps; grep of `Features/` for `@thrdspaces.com` returns nothing.
- **Gate:** exit tests may not run until T7b has merged.

### T7b — Edge Functions: `delete_account` + `submit_report` + `manage_block` (D4) — **Opus, separate delegation** *(A2)*
- **Reads:** `docs/security/edge-functions.md` (Artifact B Phase-1 slice, from T3), threat-model.md Layer 5, `supabase/migrations/0001_initial_schema.sql`.
- **Writes:** `supabase/functions/delete_account/`, `supabase/functions/submit_report/`, `supabase/functions/manage_block/` only.
- **Contract:** each function: server-side JWT verification (no trust in client claims), per-user + per-IP rate limit, audit-log write, kill-switch feature flag, errors that leak no schema. `reporter_id` derived from the verified JWT. `delete_account`: 30-day grace then hard purge; audit refs keyed by anonymized user hash. `submit_report`: rate-limited per reporter, deduplicated against existing open reports.
- **Review gate (A2):** orchestrator reviews both functions line-by-line against the Artifact B spec **before merge**. Findings go back as numbered fix tasks; no approve-with-comments.
- **Exit:** both functions deploy to local Supabase; hostile tests pass: unauthenticated invocation rejected; user A cannot delete user B's account; duplicate report is deduplicated; rate limit trips and returns a non-leaking error.

### T8 — LocationManager & permission flow — **Sonnet**
- **Reads:** threat-model.md Layer 7 (location minimization), app-store-plan.md Guideline 5.1.5.
- **Writes:** `Core/Location/LocationManager.swift` (When-In-Use only, reduced accuracy default, publishes coarse coordinate + geohash-5 helper), `Info.plist` `NSLocationWhenInUseUsageDescription` = "Thrd Spaces uses your location to show cafes, events, and communities near you."
- **Contract:** exposes `home_geohash` candidate at precision 5 only; raw coordinates never persisted, never sent to the server in Phase 1.
- **Exit:** permission prompt appears only after T6's primer; denial leaves the app functional (Discover shows permission-off empty state); no `NSLocationAlwaysUsageDescription` anywhere.

### T9 — Empty Discover shell wiring — **Sonnet**
- **Reads:** T1/T2/T8 outputs, PRD §3 Tab 1.
- **Writes:** `Features/Discover/DiscoverView.swift`, `DiscoverViewModel.swift` (extracted from the monolith; keeps `MockDiscoverRepository` behind a repository protocol for the Phase 2 Supabase swap; empty state when location denied).
- **Contract:** repository protocol returns `[Space]`/`[Event]` shaped exactly per PRD §2, so Phase 2 swaps the implementation without touching views. UI must show only fields the Phase 2 backend will actually provide.
- **Exit:** signed-in user lands on Discover; mock map + bottom sheet render; RSVP tap prints to console (no backend call); location-denied state renders. Additionally (from T1 review, see tech-debt TD1/TD2): SpaceMarker gets an accessibility label + button trait; the duplicated Bengaluru default coordinate collapses into one constant.

### T10 — Phase exit verification — **Orchestrator (Fable)**
- **Reads:** everything above.
- **Writes:** appends completion notes to this file; updates CLAUDE.md with persistent learnings; drafts `.claude/plans/phase-2.md` (stops for user review per Loop 4).
- **Exit:** full walkthrough on device of the PRD exit criteria; hostile-user RLS suite green; grep of repo + built product for `service_role` empty; every T-task has an approval note below.

---

## Non-negotiable guards active this phase

RLS default-deny on every table (T3) · service-role key nowhere in repo/bundle (T3, T4, T10 grep) · tokens Keychain-only with `WhenUnlockedThisDeviceOnly` (T4) · no client-supplied authorization fields (T3, T7a, T7b) · no image upload until CSAM pipeline exists (D2, T7a) · age gate (D3, T6) · accessibility labels on every interactive element (all UI tasks) · input validation at every trust boundary (T5–T7b).

## User actions required (as of 2026-07-12 — blocking full E2E)

1. **Hosted database has NO schema yet.** Migrations 0001/0002 exist only locally. From repo root: `supabase link --project-ref emfzwfnfsqhhybnzfhsy` (needs your Supabase login) then `supabase db push`. Until then, every table-touching client path (ensureUserRow, interests, consent audit) fails against the live project.
2. **Edge Functions not deployed to the hosted project**: `supabase functions deploy delete_account submit_report manage_block` + `supabase secrets set THRD_JWT_SECRET=<project JWT secret>`. Until then, T7a's delete/report/block flows 404 against production.
3. Apple provider + SMS sender in the Supabase dashboard (docs/manual-verification/T5.md §A), then the T5 on-device pass (§B–E).
4. At device-deploy time: `com.apple.developer.declared-age-range` entitlement + App Store Connect provisioning (age API returns nothing without it; attestation fallback covers the gap).

## Risks / notes for the user

1. **User action required before T4:** create the Supabase project (paid tier eventually, free fine for now) and provide URL + anon key. The service-role key stays in the Supabase dashboard and, later, Edge Function env — I will never ask for it and no task may accept it.
2. Phase 1 is heavier than the PRD's three bullet points because security/compliance docs pin report/block/EULA/deletion/age-gate here (D1). If you'd rather push any of these to Phase 2, say so and I'll amend D1 and re-cut the plan.
3. Declared Age Range API behavior on simulators/older iOS is untestable in places; T6's exit test uses a device profile in a regulated region where possible, self-attestation path otherwise.

## Task approval log

*(Loop 3 appends one line per approved task here.)*

- **T1 — APPROVED** (2026-07-11, commits `862ba60` + fix `ae1d84a`). Restructure + 5-tab shell clean, no scope creep, build green. One review finding fixed via T1.1 (tab accessibility-label placement); two mock-file findings deferred to T9 as TD1/TD2; placeholder duplication logged as TD3 (self-liquidating).
- **T2 — APPROVED** (2026-07-11, commit `2ba5069`). Four DesignSystem files + Theme extraction, exact scope, build green, light/dark previews, a11y traits present. Review: approve; terracotta-on-white contrast (~3.5:1, below AA for normal text) logged as TD4 for token tuning before the T10 accessibility pass.
- **T3 — COMPLETE** (2026-07-11, commit `e3f08e6` in parent repo). Migration applies to fresh local stack; hostile-user suite passes end-to-end; zero public tables without RLS (verified by query and by the migration's self-check). Artifacts A+B written; D4 logged (manage_block Edge Function).
- **T7b — APPROVED** (2026-07-11, commits `a40d4ee` + fix `5b18cc9`, parent repo). Line-by-line A2 review against Artifact B passed: JWT sig-before-parse with alg pinning, identity from JWT only (empirically confirmed), idempotent handlers, no state leaks, RPC locked to service_role (independently re-verified). One fix task T7b.1 (unauthenticated audit-flood, Tier-4) applied and verified. Spec amendments folded back into Artifact B (envelope order, identified-only auditing, `500 internal`, best-effort signOut, verify_jwt deploy posture); D5 logged for column-scoped service_role grants. Reminder for deploy: `supabase secrets set THRD_JWT_SECRET`.
- **T4 — APPROVED** (2026-07-11, commit `316afe9`). Keychain store re-asserts `WhenUnlockedThisDeviceOnly` on every write; SDK sessions routed through it via AuthLocalStorage; random-UUID fingerprint; 6/6 tests green incl. attribute + leak-canary assertions; live auth ping 200; `service_role` grep clean. New hosted test target + shared scheme added (pbxproj hand-edit). Housekeeping for T10: gitignore `xcuserdata/`.
- **T5 — APPROVED, client-side** (2026-07-11, commit `adc7f3a`). Nonce lifecycle correct and tested; auth boundary in one file; non-leaking errors; 14/14 tests; live-backend OTP error surfaced gracefully (`phone_provider_disabled` — SMS provider not yet configured). On-device exit criteria tracked in docs/manual-verification/T5.md, open pending user's dashboard config + device pass. TD5 logged (placeholder-handle collision at scale). T6 inherits two hard requirements: re-ensure user row on coordinator entry; `await auth.session` refresh-on-launch.
- **T6 — APPROVED** (2026-07-12, commit `72737e8`). Age gate fails closed, consent-write-before-active with retry, A1 metadata byte-exact (accepted interpretation: `api_result` = coarse `18_or_over`/`under_18` category — more private than raw range), interest slugs validated client-side as the trust boundary, both T5 ponytails closed. pbxproj auto-change scanned: legitimate test-target dependency only. Deploy-time prerequisite added to user actions: `com.apple.developer.declared-age-range` entitlement + provisioning before the age API returns real results (attestation fallback until then).
- **T7a — APPROVED, client-side** (2026-07-12, commit `f0d43c2`). Identity never in request bodies (verified by read); deletion signs out only on confirmed 200; A3/D2 held; 38/38 tests. Hosted schema/functions were absent → mocked-transport verification; live E2E deferred to docs/manual-verification/T7a.md pending user deploy. Phase 2 note: re-mount ReportSheet's ⋯ menu on public profiles when they exist.
- **T8 — APPROVED** (2026-07-11, commit `a521576`). LocationManager clean: reduced accuracy, geohash-5 hard cap verified against known vector, no auto-prompt, no persistence/networking, purpose string in built product. Review notes for T9: consider one-shot `requestLocation()` per Discover appearance instead of continuous updates; Swift-6 strict-concurrency delegate conformance will need attention at language-mode bump.
