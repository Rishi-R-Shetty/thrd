# Phase 2 Adversarial Security Audit — July 2026

**Date:** 2026-07-17 · **Scope:** Phase 2 backend as shipped in migrations 0001–0004 + Edge Functions (`delete_account`, `submit_report`, `manage_block`, `rsvp_event`, `purge_deleted_accounts`) + `_shared/` envelope + the hostile suite.
**Method:** Six adversarial finder dimensions (purge, RLS-matrix at scale, rate-limit/cost-amplification, D8 geo boundary, envelope compliance, grants/privesc). Every finding below was **re-verified line-by-line against source by the orchestrator** (the workflow's automated verify pass was partially lost to a session limit, so no finding here rests on an unverified agent claim).

**Headline:** No authorization break that lets user A read/write user B's owned rows was found — the core RLS matrix, the purge atomicity/ownership model, `consume_rate_limit` atomicity, and the D8 input-coarsening boundary are all sound (see §4 Clean classes). The real exposures are: one **non-negotiable-guard gap that is already scheduled but not yet built** (blocked-user invisibility in `attendee_previews`), one **rate-limit bypass** (spoofable client IP), one **incomplete-erasure DPDP gap** in purge, and a cluster of **latent / hardening** items. None blocks continued Phase 2 work; several **must** be closed before any TestFlight/App Store build ships.

---

## 1. Findings by severity

| # | Sev | Dimension | Title | Location | Disposition |
|---|-----|-----------|-------|----------|-------------|
| F1 | **HIGH** | rls / geo | `attendee_previews` (and `nearby_events` via host) has **no blocked-pair exclusion** — a blocked user stays visible in the attendee view | `0003_geo_reads.sql:46-57` | **Already = T18/0005 (not yet built).** Must land before ship. Widen scope (see F1b). |
| F1b | **HIGH** | rls | `public_profiles` direct lookup also has no blocked-pair filter, and T18 scope did **not** include it | `0001:213-219` | **New — add to T18 scope** (decision D13). |
| F2 | **HIGH** | rate-cost | Per-IP rate limit trivially bypassed — client-supplied `X-Forwarded-For` **leftmost** hop is trusted | `_shared/http.ts:33` | **New fix — Phase 3 hardening 0006.** |
| F3 | **MED-HIGH** | purge | Erasure incomplete: purged user's UUID survives in other users' `audit_log.metadata` (`subject_id`/`target`) and in `reports.subject_id` | `0004:270-275` | **New fix — Phase 3 erasure-integrity task (folds into D12).** |
| F4 | **MED** | rls | Table-wide `SELECT` grant on `tickets` exposes `qr_code_token` to every event host across the whole attendee list (column-scoping discipline not applied) | `0001:192` | **New fix — 0006** (latent: `qr_code_token` is an unused stub today). |
| F5 | **MED** | rate-cost / envelope | Kill-switch DB read (`feature_flags`) runs **before** JWT verify — an anon-key holder drives unthrottled DB reads with no rate limit | `_shared/envelope.ts:106` | **Design decision — contradicts Artifact B envelope order; resolve (D14).** |
| F6 | **MED** | rate-cost / geo | Discovery RPCs (`nearby_spaces`/`nearby_events`/`attendee_previews`) are directly client-callable with **no rate limit** — unthrottled enumeration into a movement-pattern dossier at exact venue coords+times | `0003:146-148` | **New fix — 0006 + Phase 3.** |
| F7 | **MED** | rate-cost | `consume_rate_limit` writes each bucket **before** the deny decision, and there is no TTL/sweep → unbounded `rate_limit_counters` growth (compounds F2) | `0002:97` | **New fix — 0006** (add the deferred sweep). |
| F8 | **MED** | purge | Whole nightly purge runs in **one transaction** (function, not procedure): at thousands of eligible users it holds cascade locks for the entire run and isn't incrementally durable | `0004:258` | **New fix — Phase 3** (convert to per-user COMMIT / batched procedure). |
| F9 | **MED** | envelope | Hostile suite never exercises JWT **alg-confusion / expired / no-exp** tokens against the sole load-bearing auth control | `tests/*` | **New test coverage — 0006 test pass.** |
| F10 | LOW | purge | Skipped erasures (RESTRICT FK / any swallowed exception) leave **no durable record** — only an ephemeral `NOTICE` | `0004:282` | **New — fold into D12** (durable `purge_skipped` audit row). |
| F11 | LOW | rls | `nearby_*` return **unbounded** result sets — no `LIMIT`/pagination | `0003:101` | **New fix — 0006** (add `LIMIT` + keyset). |
| F12 | LOW | envelope | JWT verifier **fails open** on missing `exp` — a validly-signed token with no expiry never expires | `_shared/jwt.ts:76` | **New fix — 0006** (fail closed on missing/non-numeric `exp`). |
| F13 | LOW | geo | `attendee_previews.avatar_url` is a latent stable cross-event correlator once avatar uploads ship (Phase 3) — no gate forces re-review | `0003:50` | **New — decision link** (already tied to D2 CSAM unlock; add re-review gate). |
| F14 | LOW | rls | `public_profiles` blocked-pair (as F1b) — direct-lookup variant | `0001:216` | Merged into F1b. |
| F15 | LOW | grants | Definer views (`public_profiles`, `attendee_previews`) have **no defensive `REVOKE ... FROM anon`** — rely solely on the not-auto-exposed Data-API default | `0001:219`, `0003` | **New fix — 0006** (belt-and-suspenders revoke). |
| F16 | LOW | envelope | No hostile assertion that 401/503 rejections write **zero** `audit_log` rows (the Tier-4 anti-amplification invariant is unverified) | `_shared/envelope.ts:166` | **New test — 0006 test pass.** |
| F17 | INFO | grants | `consume_rate_limit` doesn't assert its owner (unlike `purge_deleted_accounts`) — DEFINER identity non-deterministic across deploys | `0002:70` | **New one-liner — 0006** (`alter function ... owner to postgres`). |
| F18 | INFO | grants | Hostile suite asserts `audit_log` UPDATE-immutability vs service_role but not **DELETE** | `tests:442` | **New test — 0006.** |
| F19 | INFO | geo | Doc drift: threat-model Layer 4 says ~500m geohash grid; implementation + D8 use geohash-5 (~2.4km, *coarser* = safer) | `threat-model.md:82` | **Doc reconcile** (annotate finer precision as a deliberate non-goal). |

---

## 2. What must ship before any build goes public

Phase 2 is not yet complete (T18–T21 queued), so none of these are "shipped vulnerabilities" — but each is a hard gate for a TestFlight/App Store build:

1. **F1 / F1b — blocked-user invisibility.** The non-negotiable guard ("blocked users invisible in every list, feed, attendee view") is currently unmet in `attendee_previews` and `public_profiles`. T18 already owns the `attendee_previews`/`nearby_events`/communities exclusion; **widen T18 to include `public_profiles`** and add the hostile assertions the audit named (F1's test gap). Until then, the client grant on `attendee_previews` is live without the filter.
2. **F2 — client-IP spoofing.** Fix `clientIp()` before relying on any per-IP limit for launch abuse control.
3. **F3 / F10 — DPDP erasure completeness + observability.** Fold into the Phase 3 erasure-integrity task (D12): re-key every UUID appearance (metadata `subject_id`/`target`, `reports.subject_id`), and write a durable `purge_skipped` audit row.

---

## 3. Verified-against-source detail for the load-bearing findings

**F1/F1b (`0003:46-57`, `0001:213-219`).** `attendee_previews` WHERE clause is `t.status='going' AND e.status='published' AND u.deletion_requested_at IS NULL` — no `blocks` predicate. `public_profiles` filters only `profile_visibility='public' AND deletion_requested_at IS NULL`. Both are `security_barrier` definer views, so the fix is a both-directions `NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id=u.id AND b.blocked_id=auth.uid()) OR (b.blocker_id=auth.uid() AND b.blocked_id=u.id))`. Confirmed no `0005` migration exists yet.

**F2 (`http.ts:33`).** `xff.split(",")[0].trim()` takes the **leftmost** value — the one an untrusted client injects (proxies append to the right). On Supabase Edge the trustworthy hop is the **rightmost** value appended by the platform proxy. Fix: take the last hop, or a platform header the client can't forge. Mitigation today: the per-**user** JWT cap still holds, so this degrades — not eliminates — abuse protection; account rotation defeats the per-user cap, which is exactly what per-IP was meant to catch.

**F3 (`0004:270-275`).** Re-key is `UPDATE audit_log SET user_id=NULL, metadata=... WHERE user_id=v_uid` — only the **actor** column. `submit_report` writes `metadata.subject_id=<subject uuid>` (`submit_report/index.ts`), `manage_block` writes `metadata.target=<uuid>`, and `reports.subject_id` (polymorphic, no FK → survives the cascade) all retain the purged UUID. Phase-2-reachable because report/block are live since Phase 1. Fix: extend the re-key to those appearances with the same salted hash.

**F4 (`0001:192`).** `grant select on public.tickets to authenticated` is table-wide, unlike `spaces` (deliberately re-scoped column-wise in `0003:26-29` to hide `source_ref`). `tickets_select_own_or_host` gives a host every attendee ticket row → including `qr_code_token`. Latent only because no code issues a token yet (Phase 3 QR check-in). Fix now (cheap): `revoke` + column-scoped `grant` excluding `qr_code_token`. **Note:** T17's `ownActiveTickets()` already uses an explicit column list, so the client path is clean — this closes the *direct* `select qr_code_token` a host could otherwise run.

**F5 (`envelope.ts:106`).** Kill switch (a `feature_flags` service-role SELECT) is step 1; JWT verify is step 2. An anon-key holder (valid gateway JWT, but `role≠authenticated` → our `verifyJwt` returns null) triggers one DB read per request before the 401, with no rate limit. **This is the order Artifact B explicitly specifies** ("kill switch first … the only pre-auth DB touch"), so fixing it is an Artifact B amendment, not a bug fix — hence decision D14. JWT verify is CPU-only HMAC (no DB), so verifying first rejects tokenless/invalid at zero DB cost while keeping the kill switch as the only pre-*effect* DB touch.

**F12 (`jwt.ts:76`).** `if (typeof payload.exp === "number" && payload.exp <= now) return null;` — a token with no `exp` skips expiry entirely. Exploitability is low (minting an exp-less token requires the signing secret, which is the whole trust root; Supabase-issued tokens always carry `exp`), but fail-closed is correct: treat missing/non-numeric `exp` as invalid.

---

## 4. Clean classes (adversarially tested, no finding) — do not "re-fix" these

- **Purge atomicity & ownership.** Per-user `begin/exception` is a savepoint, so a re-key never survives a failed delete (the D11 RESTRICT rollback is correct-as-designed: skip-and-continue, never whole-run abort). `SECURITY DEFINER OWNER postgres` + `revoke all from public` is the sole `audit_log` UPDATE path; neither `authenticated` nor `service_role` can invoke it (hostile-tested). Pepper is Vault-backed and fails closed if absent. Grace predicate is timezone-safe (`timestamptz` absolute-instant comparison).
- **Core RLS matrix.** `nearby_*`/`assert_geohash5` are `SECURITY INVOKER` with pinned `search_path` (they ride the caller's own RLS — the audit's initial "DEFINER" premise was wrong and self-corrected). No `authenticated` INSERT/UPDATE on `events`, so host status is unforgeable. `reports` (zero policies), `audit_log` (insert-consent-only, immutable even to service_role), `feature_flags`/`rate_limit_counters` (zero client grants) are invisible/unwritable to a hostile client. No accidental `USING(true)` beyond the intended public-venue `spaces` read.
- **`consume_rate_limit` atomicity.** `insert … on conflict do update set count=count+1 returning count` is a single atomic statement — no check-then-increment race; N concurrent calls at limit=1 serialize to distinct counts. Both per-user **and** per-IP buckets are enforced (deny if *any* exceeds) — the only weakness is the IP *key* (F2), not the enforcement.
- **D8 input coarsening.** `assert_geohash5` hard-rejects 6+ char and raw-coord inputs; the origin is the cell **center**, so any two positions in one cell collapse to the same server origin (no finer-than-cell resolution). Radius cap `least(greatest(radius_m,100),10000)` and 30-day horizon are server-enforced. Both RPCs are pure `stable` reads — the caller cell is never persisted or logged.
- **T7b.1 audit-flood fix** is applied everywhere via the shared `finally` block (`audit_log` written only when `callerId !== null`); `rsvp_event` inherits it; purge has no HTTP caller.

*Intended-by-design (not findings): `attendee_previews` deliberately shows first-name+avatar for private-profile users who RSVP a published event (attending a public event is a public act, D-logged); a published event of a private community is discoverable while the community row stays hidden.*

---

## 5. Disposition → work items

- **T18 (Phase 2, queued):** widen to include `public_profiles` blocked-pair filter + the F1/F1b/F16/F18 hostile assertions. → **D13**.
- **New Phase 3 migration `0006_phase2_hardening.sql`:** F2, F4, F6, F7, F11, F12, F15, F17 + the F9/F16/F18 hostile-suite pass. (Batch of low-risk, high-value hardening — column-scope tickets, IP source fix, geo rate-limit + LIMIT, counter sweep, definer-view anon revoke, JWT fail-closed, owner assertions.)
- **Phase 3 erasure-integrity task (the D12 deliverable):** absorbs F3 (complete UUID re-key) and F10 (durable `purge_skipped` row) and F8 (batched/committing purge).
- **Decisions to log:** D13 (T18 scope widen), D14 (envelope order — resolve F5), plus F19 doc reconcile.
- **F13:** attach an explicit re-review gate to the D2 CSAM-avatar unlock so `attendee_previews.avatar_url` exposure is reconsidered when uploads ship.
