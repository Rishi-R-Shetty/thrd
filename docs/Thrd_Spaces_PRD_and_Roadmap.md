# Thrd Spaces — Product Requirements Document, Architecture & Development Roadmap

**Platform:** iOS (Swift / SwiftUI) · **Version:** MVP v1.0 · **Prepared:** July 2026

---

## 1. Executive PRD

### Value Proposition
Thrd Spaces is the operating system for offline social life. It helps people discover third places (cafes, parks, studios, cultural venues), join real-world communities, and attend recurring events — solving modern loneliness by optimizing for *meaningful offline interaction*, not screen time.

### The Core Loop
1. **Discover** — User opens the app and sees nearby spaces and events matched to their interests via an AI recommendation layer.
2. **Join** — User RSVPs to an event or joins a community with one tap.
3. **Show Up** — Location-aware check-in confirms real-world attendance.
4. **Belong** — Post-event, the user connects with people they met, earns member-tier progression in communities, and gets better recommendations.
5. **Return** — Recurring events, community boards, and friend activity pull the user back into the real world (not the feed).

### Success Metrics (North Star + Supporting)
- **North Star:** Monthly Real-World Attendances (verified check-ins) per active user.
- Community retention: % of members attending ≥2 events in 30 days.
- Host success: % of communities running a recurring event within 60 days of creation.
- Space partner ROI: incremental foot traffic per listed venue.
- Anti-metric guardrail: session time is deliberately *not* a growth KPI.

### What Thrd Spaces Is Not
- Not a dating app (no swipe mechanics, no appearance-first profiles).
- Not a content feed (no infinite scroll; discovery surfaces are bounded and intentional).
- Not a pure ticketing tool (ticketing exists to serve community continuity, not one-off events).

---

## 2. App Architecture & Data Model

### High-Level Architecture

```
┌──────────────────────────────────────────────────────┐
│                    iOS App (SwiftUI)                  │
│  MVVM + Repository pattern, Swift Concurrency        │
│  MapKit · CoreLocation · PushKit · StoreKit 2        │
└───────────────┬──────────────────────────────────────┘
                │ HTTPS / Realtime (WebSocket)
┌───────────────▼──────────────────────────────────────┐
│              Backend: Supabase (recommended MVP)      │
│  • Postgres + PostGIS (geo queries, relational data) │
│  • Supabase Auth (Apple Sign-In, phone OTP)          │
│  • Realtime channels (chat, RSVP counters)           │
│  • Edge Functions (business logic, verification)     │
│  • Storage (avatars, space photos, event covers)     │
└───────────────┬──────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────┐
│  AI/ML Layer (Phase 4)                                │
│  • Recommendation service (pgvector embeddings)      │
│  • Interest ↔ Space/Event matching                   │
│  • Ranking: distance × interest similarity ×         │
│    social proof × recency × host quality score       │
└──────────────────────────────────────────────────────┘
```

**Why Supabase for MVP:** PostGIS gives production-grade geospatial queries (radius search, bounding-box map queries) on a relational model — a genuinely better fit than Firestore for Users↔Events↔Tickets↔Communities relationships. pgvector enables the Phase 4 recommendation engine without adding a new vendor. Migration path to AWS exists if scale demands it.

### Core Entities

**User**
`id, handle, display_name, avatar_url, bio, interests[] (tag ids), home_geohash (coarse, privacy-safe), verification_status (none|phone|id_verified), trust_score, created_at`

**Space** (a physical third place)
`id, owner_user_id (nullable — claimed vs unclaimed), name, category (cafe|park|studio|venue|other), location (PostGIS point), address, photos[], amenities[], hours, capacity, is_partner (bool), rating_agg`

**Community**
`id, creator_id, name, description, cover_url, interest_tags[], visibility (public|approval|private), member_count, home_space_id (nullable), created_at`

**CommunityMembership**
`community_id, user_id, role (member|moderator|host), tier (newcomer|regular|core), joined_at, events_attended_count`

**Event**
`id, community_id (nullable for standalone), host_id, space_id, title, description, cover_url, starts_at, ends_at, recurrence_rule (RFC 5545 RRULE), capacity, price (0 = free), status (draft|published|cancelled|completed), rsvp_count`

**Ticket / RSVP**
`id, event_id, user_id, type (rsvp|paid), status (going|waitlist|checked_in|cancelled), qr_code_token, purchased_at, checked_in_at`

**Message**
`id, channel_id, sender_id, body, media_url, sent_at` — with **Channel** `(id, type: dm|group|community, member_ids[])`

**Report** (Trust & Safety)
`id, reporter_id, subject_type (user|event|community|message), subject_id, reason, status (open|reviewed|actioned), created_at`

**Key relationships:** User ↔ Community (many-to-many via Membership) · Community → Events (one-to-many) · Event → Space (many-to-one) · Event ↔ User (many-to-many via Ticket).

---

## 3. UI Flow & Screen Breakdown (MVP)

### Navigation Shell — 5 Tabs
`Discover · Communities · ➕ Create · Messages · Profile`

### Onboarding Flow (first launch)
1. **Welcome carousel** (3 screens: the third-space idea, communities, safety) — warm illustration style, skippable.
2. **Sign in** — Sign in with Apple (primary) + phone OTP fallback.
3. **Interest picker** — chip-grid of 8–12 categories (books, running, chess, coffee, music, wellness, art, food, sport, tech, language, board games); pick ≥3.
4. **Location permission** — value-first prompt ("Find spaces within walking distance") before the system dialog.
5. **Land on Discover.**

### Tab 1 — Discover
- **Map view (default):** MapKit with custom warm-toned annotations; clustering at low zoom; pill filters on top (Today · This Week · Free · Category chips); bottom sheet with "Near you now" cards.
- **List view (toggle):** ranked cards — event/space photo, title, distance, time, "3 friends going" social proof, one-tap RSVP.
- **Detail screens:** Space Detail (photos, hours, communities that meet here, upcoming events) and Event Detail (host, venue map snippet, attendee avatars, RSVP/Buy CTA).

### Tab 2 — Communities
- **My Communities** (horizontal cards with next-event badge) + **Suggested for you**.
- **Community Home:** cover, description, member tier badge, upcoming events list, **Community Board** (pinned announcements + threaded posts), members grid.

### Tab 3 — Create (center action)
- Chooser: **Create Event** / **Start a Community** / **List a Space**.
- **Event creation wizard (4 steps):** Basics → Venue (search Spaces or drop pin) → Schedule (with recurrence: weekly/biweekly/monthly) → Tickets (free RSVP, capacity, or paid).
- **Host dashboard:** RSVP list, QR check-in scanner, attendance analytics (attendance rate, repeat-attendee %, growth chart).

### Tab 4 — Messages
- Inbox: DMs, group chats, community channels in one list with unread states.
- Chat screen: text + photo, event-card sharing, realtime via Supabase channels.

### Tab 5 — Profile
- Public profile: avatar, verified badge, interests, communities, "42 events attended" stat.
- Settings: verification (phone → ID), privacy (location granularity), blocked users, notifications.

### Trust & Safety surfaces (cross-cutting)
- Report action on every profile, event, community, and message (long-press / ⋯ menu).
- Verified-host badge; first-time-attendee safety sheet before an event ("Meet in public areas, tell a friend").
- Block propagates across chat, discovery, and attendee lists.

---

## 4. Phased Development Roadmap

### Phase 1 — Core Setup & Auth (Weeks 1–3)
- Xcode project, folder architecture (below), design system (colors, typography, spacing tokens, reusable components: ThrdButton, ThrdCard, ChipGroup).
- Supabase project: schema migration for User/Space/Event/Community tables, RLS policies.
- Sign in with Apple + phone OTP; onboarding flow incl. interest picker.
- Profile create/edit; CoreLocation permission flow.
- **Exit criteria:** a user can sign up, set interests, and see an empty Discover shell.

### Phase 2 — Discovery & Maps (Weeks 4–7)
- MapKit map with PostGIS-backed bounding-box queries; annotation clustering.
- List view with distance-sorted ranking (simple heuristic: distance + interest tag overlap).
- Space Detail & Event Detail screens; seed content pipeline (admin import of 100–200 spaces for launch city).
- Basic RSVP (free events) with capacity + waitlist.
- **Exit criteria:** a user can find a real event nearby and RSVP.

### Phase 3 — Community Toolkit (Weeks 8–12)
- Community creation, membership roles, member tiers (newcomer → regular → core, driven by check-ins).
- Event creation wizard with RRULE recurrence; host dashboard with QR check-in and analytics.
- Community Board (posts + pins); paid ticketing via StoreKit 2 / payment link (regulatory-dependent).
- Push notifications: event reminders (24h/2h), RSVP confirmations, community announcements.
- **Exit criteria:** a host can run a recurring weekly event end-to-end without leaving the app.

### Phase 4 — Social & AI (Weeks 13–17)
- DMs, group chat, community channels (Supabase Realtime).
- Friend circles; "friends going" social proof in Discover.
- Recommendation engine: pgvector embeddings of interest tags + attendance history; ranked Discover feed (distance × similarity × social proof × host quality).
- Trust & Safety hardening: ID verification (third-party KYC), report review queue, moderation tools for hosts.
- **Exit criteria:** Discover feels personal; two users can meet at an event and continue the conversation in-app.

---

## 5. Immediate First Step

### Folder Structure

```
ThrdSpaces/
├── App/
│   ├── ThrdSpacesApp.swift
│   └── RootTabView.swift
├── Core/
│   ├── DesignSystem/
│   │   ├── Theme.swift            // colors, typography, spacing tokens
│   │   ├── ThrdButton.swift
│   │   ├── ThrdCard.swift
│   │   └── ChipGroup.swift
│   ├── Networking/
│   │   ├── SupabaseClient.swift
│   │   └── APIError.swift
│   ├── Location/
│   │   └── LocationManager.swift
│   └── Extensions/
├── Models/
│   ├── User.swift
│   ├── Space.swift
│   ├── Event.swift
│   ├── Community.swift
│   └── Ticket.swift
├── Features/
│   ├── Onboarding/
│   ├── Discover/
│   │   ├── DiscoverView.swift     // ← first screen to build
│   │   ├── DiscoverViewModel.swift
│   │   ├── SpaceAnnotationView.swift
│   │   └── EventCardView.swift
│   ├── Communities/
│   ├── Create/
│   ├── Messages/
│   └── Profile/
└── Resources/
    └── Assets.xcassets
```

The first SwiftUI code (DiscoverView + supporting model/view-model) is provided in **DiscoverView.swift** alongside this document — it compiles standalone with mock data so you can see the map + bottom-sheet UI immediately, then swap the mock repository for Supabase in Phase 2.
