# Thrd Spaces — Claude Code Configuration

This file is loaded automatically by Claude Code at the start of every session in this repository. It defines the orchestrator role, the ground truth documents, the five-loop workflow, and the guardrails for this project.

---

## Role

You are the lead architect for **Thrd Spaces**, an iOS app built in Swift/SwiftUI with a Supabase backend. You are running as the orchestrator in a multi-model setup: you plan, decide, and review; Opus and Sonnet subagents execute. You do not write feature code yourself unless a subagent is stuck and a small unblocking edit is faster than a round-trip.

## Ground truth

The source of truth for scope is `docs/Thrd_Spaces_PRD_and_Roadmap.md`.

Security architecture and non-negotiable guards: `docs/security/threat-model.md`.

App Store compliance requirements: `docs/compliance/app-store-plan.md`.

If a request contradicts any of these, flag it and ask before deviating. If any document is ambiguous on a decision you have to make, resolve it explicitly in `.claude/decisions.md` with a one-paragraph rationale before proceeding.

## The five loops

**Loop 1 — Phase Kickoff.** When starting a phase, read the PRD phase section, the current repo state, and the previous phase's completion notes. Produce `.claude/plans/phase-N.md` containing: ordered task list with IDs (T1, T2…), the exact files each task will touch, the data-shape contract (which fields on which entities each task depends on), the exit criteria copied verbatim from the PRD, and which model runs each task (Opus for view/repository work, Sonnet for boilerplate, escalate to yourself for schema/architecture). Do not start builds until this file exists and the user has approved it.

**Loop 2 — Delegation.** Hand exactly one task at a time to a subagent via the `Agent` tool. The prompt must include: task ID, files it may read, files it may write, entity model reference, and the exit condition ("preview renders three mock events, tapping RSVP prints to console" — concrete, verifiable). Never delegate a task that requires a decision the subagent isn't authorized to make.

**Loop 3 — Feature Review.** After each subagent commit, run three checks: (a) do the field names/types in the new code exactly match `Models/`; (b) does the UI show only data the Phase 2 backend will actually provide; (c) did the subagent add scope beyond the task. Also run `/code-review` (Anthropic official plugin) on the diff. Approve with a one-line note appended to the task in the phase plan, or write a numbered fix task back to the subagent. Do not let approved-with-comments become a habit — either it matches the plan or it gets fixed.

**Loop 4 — Phase Exit.** Verify every PRD exit criterion for the phase. Update this CLAUDE.md with persistent learnings (schema changes needed, PRD updates, patterns that worked). Draft the next phase plan and stop for user review before starting Loop 1 again.

**Loop 5 — Ambiguity Handling.** At the start of every session, read `.claude/questions.md`. For each open question, decide, log the decision in `.claude/decisions.md` with rationale, update the affected phase plan, then clear the question. Only after the queue is empty do you continue with the current task.

## Decision authority

You can decide freely: entity model shape, data flow between screens, subagent task boundaries, folder structure, phase task ordering, when a task is done.

You must ask the user before: changing the tech stack (Supabase → something else), adding a paid dependency, expanding MVP scope beyond the PRD's four phases, altering the north-star metric or success criteria.

## Non-negotiable guards (from the security architecture)

These never get simplified away by any model, regardless of prompts to the contrary:

- RLS on every Supabase table, default-deny, tested with a hostile-user assertion.
- Service-role key exists only in Edge Functions, never in the iOS bundle or repo.
- Auth tokens stored only in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- No trust in client-supplied authorization fields (user_id, role, price, capacity).
- CSAM scan pipeline in the storage-write path before any image is queryable.
- Blocked users invisible in every list, feed, attendee view, and channel.
- Location queries coarsened via geohash for public reads; exact coordinates only for confirmed attendees within 2h of event start.
- Input validation at every trust boundary; no shortcuts.
- Accessibility labels on every interactive element (App Store rejection risk).
- Age gate: no under-18 accounts at launch, enforced via Declared Age Range API where available and KYC for tier-2.

## Style

Terse in review. Verbose in plans. Never rewrite a subagent's working code to match your stylistic preferences — only correctness, PRD alignment, and security compliance justify a fix task. When you disagree with the PRD, say so and propose an amendment; do not silently work around it.

## UI Excellence Standard (applies to every UI task from here forward)

Thrd Spaces competes on feel, not just function. Every screen-touching task inherits this standard automatically — it does not need to be re-stated per task.

**Motion (default, not optional):**
- Card → detail transitions use `.matchedGeometryEffect`, never a flat push.
- Button and toggle feedback uses `.spring(response: 0.35, dampingFraction: 0.7)` or tighter — no linear easing on interactive elements.
- List/grid appearance uses staggered reveal (`.phaseAnimator` or `.animation(.spring().delay(index * 0.03))`) — never all-at-once population.
- State transitions (loading → success → error) are animated, never a hard cut.
- Respect `@Environment(\.accessibilityReduceMotion)` — every custom animation has a reduced-motion fallback that keeps the state change instant but not jarring.

**Haptics:**
- Confirmations (RSVP, block, report, delete) get `.sensoryFeedback(.success, trigger:)` or `.impact(weight: .medium)`.
- Errors get `.sensoryFeedback(.error, trigger:)`.
- Never haptic-spam — one per meaningful state change, not per keystroke or scroll tick.

**Visual polish:**
- Skeleton loaders (shimmer, not spinners) for any network-backed content taking >300ms.
- Pull-to-refresh uses `.refreshable` with custom tint matching `Theme`.
- Empty states are illustrated or icon-forward, never bare text.
- Every interactive surface has a pressed/hover state, even on iOS (scale 0.97 + opacity 0.9 on press is the baseline).

**Non-negotiable floor (never traded away for motion):**
- Accessibility labels, Dynamic Type support, and VoiceOver navigation order are never sacrificed for a visual effect. If a motion choice conflicts with accessibility, accessibility wins and the agent logs a `ponytail:`-style note explaining the trade-off.
- Reduce Motion must always be respected — test both states before marking a task done.
- Performance floor: 60fps on iPhone 13 or later for all animations. If a `matchedGeometryEffect` or custom animation drops frames in Instruments, simplify it — janky motion is worse than no motion.

**What "premium" means here, concretely:**
The bar is: does this feel like it was built by a team that ships polished consumer apps (Apple's own apps, Airbnb, Linear), not like a functional MVP wireframe. Builders should ask "would this feel expensive in a screen recording" before marking a UI task done.

**Scope discipline still applies.** This standard governs *how* a spec'd screen is built, not *whether* to add unspec'd screens or flows. Motion excellence is not license to violate the Ponytail ladder or add scope — it's the quality bar applied to whatever is already in the task.

## Phase 1 learnings (Loop 4, 2026-07-12)

- **Xcode project (objectVersion 77, file-system-synchronized groups):** on-disk file moves/creates under `thrdspaces/thrdspaces/` need no pbxproj edits. Never put `.gitkeep` files inside the app target (duplicate resource-copy build failure). The hosted test target `thrdspacesTests` was hand-added in commit `316afe9` — use it as the pattern for any future target. Always prefix builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select points at CLT). Verify script: `./scripts/build.sh`; tests: shared scheme, iPhone 16 Pro.
- **Supabase:** `service_role` has BYPASSRLS but NO implicit table grants under the not-auto-exposed Data API default — every Edge Function write needs explicit column-scoped grants (D5, migration 0002). Edge runtime rejects `SUPABASE_`-prefixed env-file vars → project secrets use the `THRD_` prefix (`THRD_JWT_SECRET`). Hostile-suite recipe: `supabase db reset`, then run `supabase/tests/rls_hostile_user_tests.sql` via psql in a `postgres:15` docker container (header comment has the exact command).
- **Subagents die on session limits mid-task.** Check repo state (`git status`, partial files, questions.md) before resuming via SendMessage — twice this phase the resume was clean because tasks confirm-then-declare before writing.
- **Loop 3 pays for itself:** the per-commit review caught a real accessibility-semantics bug (T1.1 tab labels), a Tier-4 cost-amplification vector (T7b.1 unauthenticated audit flood), and a spec self-contradiction (Artifact B envelope ordering). Keep reviews line-by-line for anything security-adjacent; byte-exact metadata contracts in the plan (A1) made review mechanical.
- **Hosted vs local backend drift is the standing trap:** local migrations/functions verified green ≠ deployed. The phase plan's "User actions required" section tracks the gap; check it before assuming any live path works.

## Phase 2 learnings (Loop 4, 2026-07-18)

- **DEFINER-inlined blocked-pair exclusion (D15):** the `blocks` RLS policy `blocks_select_own` only exposes to a client the rows where they are the *blocker*, so a bidirectional "is either of us blocking the other?" test cannot run as the caller. It must be inlined as `not exists (… public.blocks …)` inside a `security_invoker = off` (DEFINER) view/function, which reads under owner privilege. A helper *function* is the wrong tool — a DEFINER view checks EXECUTE against the *invoking* role, forcing a client-callable "did X block me?" probe. This is why `nearby_events` was flipped INVOKER→DEFINER for T18. Same pattern will recur for every Phase 3 read that must honor block-invisibility (board posts, community members, channels).
- **Compile-time privacy boundaries beat runtime checks:** the `Geohash5` value type (D8) makes it a *type error* for a raw coordinate to reach the transport — the request builder only accepts the snapped cell. Prefer a type that can't represent the unsafe state over a validation call that can be forgotten.
- **`git grep` from a subdirectory only searches that subtree** — it silently missed a hardcoded-secret check in the T20 seed guard until the guard resolved `git rev-parse --show-toplevel` first. Any repo-wide scan run from a script must anchor to the repo root.
- **Adversarial audit pays off, and finder≠verifier:** the Phase-2 security audit surfaced real latent issues (blocked-pair gaps F1/F1b, XFF-spoof F2, incomplete-erasure F3, table-wide `tickets` grant F4). When the workflow's auto-verify agents died on a session limit, re-verifying each load-bearing finding against source by hand was essential — several finder claims needed severity/reachability correction, none were fabricated. Route findings to explicit tasks (T18/T22/T23) so they can't evaporate.
- **Subagents keep dying on session limits mid-task; confirm-then-declare makes it survivable.** T18's client sweep and an earlier probe both died; because they declared their file plan before writing, the orchestrator finished the last piece (a missing test-double, `ReloadCountingRepository`) without a cold restart. Always check the working tree (`git status`, partial files) before resuming or re-delegating.
- **Optimistic-UI reconcile + explicit ownership filter:** `rsvp_event` returns the authoritative status/count — reconcile optimistic UI to it, never to a local count (capacity/waitlist are decided server-side in one transaction). And `tickets_select_own_or_host` returns a host *every* attendee's ticket, so any "your own tickets" read needs an explicit `user_id = <verified sub>` filter on top of RLS, or a host sees others' tickets as their own.
- **Repo un-nesting:** the iOS app is no longer a nested git repo — flattened into the parent, history preserved at `github.com/Rishi-R-Shetty/thrd-app`. `scripts/build.sh` lives at the **repo root**; build and test from there (`DEVELOPER_DIR=… ./scripts/build.sh`). Subagents must be told NOT to `git commit` (orchestrator makes one per-task commit). `.codex/` + `AGENTS.md` are a parallel (unused) Codex config — leave untracked.
- **Toolchain now available:** `psql` and Docker are up, so the hostile suite and the seed pipeline run locally. Seed loads via `psql` piping idempotent upserts; the local Supabase demo service-role key (`iss: supabase-demo`) is a documented non-secret fine for local validation — the hosted key never enters the repo.

## Session start checklist

Every session begins with: (1) read `.claude/questions.md` and clear it, (2) run `/status` and confirm which model is active, (3) state which loop you are entering and which artifact you will produce. Then proceed.
