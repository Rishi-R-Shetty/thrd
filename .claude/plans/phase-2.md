# Phase 2 Plan — Discovery & Maps (Weeks 4–7) — DRAFT

**Status:** DRAFT — Loop 4 hand-off from Phase 1. Not started; awaiting user review, then Loop 1 formalizes (data-shape contract in full, per-task file lists finalized).
**Sources:** PRD §4 Phase 2 · threat-model.md §5 Phase 2 must-haves (coarsened location queries, blocked-user invisibility, first-meeting safety sheet, panic button) · Artifact A PLANNED policies · Artifact B stubs (`rsvp_event`, `purge_deleted_accounts`) · Phase 1 carry-forwards.

## Exit criteria (verbatim from PRD)

> **Exit criteria:** a user can find a real event nearby and RSVP.

## Phase 1 carry-forwards (must be absorbed, not re-litigated)

- Repository seam is ready: `DiscoverRepository` protocol (T9) — Phase 2 swaps in the Supabase implementation; the protocol needs a **distance-annotated return shape** (computed PostGIS field, never an entity field).
- `Models/` gets the real entities (Space, Event, Community, Ticket, Report) matching migration 0001 byte-for-byte; Discover's local mock types retire.
- Re-mount ReportSheet's ⋯ menu on public profiles when they become visible (T7a note); `DiscoverEvent.categoryIcon` needs a real backing decision.
- `profile_visibility` UPDATE grant + settings UI (Artifact A planned); `events_select_own_drafts` policy for hosts.
- Supabase Swift SDK privacy manifest check (compliance plan §3: "verify at Phase 2 start").
- TD4 (terracotta contrast) lands whenever the user decides — one-file token change.

## Draft task list (IDs continue from Phase 1)

| ID | Task | Model | Depends on |
|---|---|---|---|
| T11 | Models/ real entities + decoding tests against migration column names | Sonnet | — |
| T12 | Geo read layer: geohash-coarsened bounding-box RPC (SQL, ~500m snap for public reads) + `events_select_own_drafts` + `profile_visibility` grant — **migration 0003 + hostile tests** | Orchestrator | — |
| T13 | SupabaseDiscoverRepository (bounding-box + distance-annotated results) replacing the mock behind the T9 protocol | Opus | T11, T12 |
| T14 | Map: PostGIS-backed annotations + clustering; list view with distance + interest-overlap ranking | Opus | T13 |
| T15 | Space Detail + Event Detail screens (public profile view surfaces here → re-mount Report/Block ⋯) | Opus | T13 |
| T16 | `rsvp_event` Edge Function (transactional capacity + waitlist, per Artifact B stub) + `purge_deleted_accounts` pg_cron — **orchestrator reviews against Artifact B before merge (A2 pattern)** | Opus | T12 |
| T17 | RSVP UI end-to-end (free events): join/waitlist/cancel; ticket row visible to self + host only | Opus | T15, T16 |
| T18 | Blocked-user invisibility: server-side exclusion in every Phase-2 read path (feed, attendee views, detail screens) + hostile tests proving A never sees B after a block in either direction | Orchestrator (SQL) + Opus (client) | T12–T17 |
| T19 | Safety surfaces: first-meeting safety sheet (non-dismissable checkbox on first-time flow) + panic button on Event Detail within the 2h window | Opus | T15 |
| T20 | Seed pipeline: admin import of 100–200 spaces for launch city (Bengaluru) — script + data validation, service-role used ONLY from a local admin script, never shipped | Sonnet | T12 |
| T21 | Phase exit verification + Phase 3 draft | Orchestrator | all |

## Security guards with Phase-2 teeth

Coarsened geohash reads are the ONLY public location query surface (raw PostGIS operators never exposed to clients) · exact coordinates only for confirmed attendees within 2h of start (T16/T17 read path) · blocked-user invisibility is server-side, hostile-tested, in every list (T18) · capacity/waitlist decided in the Edge Function transaction, never from client counts (T16) · seed script's service-role key stays local, never committed (T20).

## Prerequisites carried from Phase 1 (user)

Schema push + function deploy + `THRD_JWT_SECRET` + auth providers (see phase-1.md "User actions required") — Phase 2's exit criteria are impossible against an empty hosted project.

## Open questions for the user before Loop 1

1. Launch city confirmed as Bengaluru (T20 seed data + default map region)?
2. Seed-data source: manual curation, Google Places import (licensing!), or a mix? Licensing constraints affect T20's design.
3. TD4 terracotta decision (can ride along with any Phase 2 UI task once made).
