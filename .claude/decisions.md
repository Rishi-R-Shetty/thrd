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
