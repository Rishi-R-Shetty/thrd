-- ============================================================================
-- Thrd Spaces — 0001_initial_schema.sql (Phase 1, task T3)
-- Executable truth for the Phase 1 schema. The annotated policy specification
-- (including future-phase policies) lives in docs/security/rls-policies.sql.
--
-- Non-negotiable guards enforced here:
--   * RLS enabled, default-deny, on EVERY table in this same migration.
--   * No client-writable authorization fields: trust_score, verification_status,
--     reporter_id, blocker_id, deletion_requested_at, rsvp_count, member_count
--     have no INSERT/UPDATE grant for anon/authenticated.
--   * audit_log is insert-only for every role including service_role.
--   * Location: home_geohash capped at precision 5 (~2km). Exact coordinates
--     exist only on spaces.location (venues, public by nature).
-- ============================================================================

create extension if not exists postgis with schema extensions;

-- ─────────────────────────────────────────────────────────────── enums ──────

create type public.verification_status  as enum ('none','phone','id_verified');
create type public.space_category       as enum ('cafe','park','studio','venue','other');
create type public.community_visibility as enum ('public','approval','private');
create type public.membership_role      as enum ('member','moderator','host');
create type public.membership_tier      as enum ('newcomer','regular','core');
create type public.event_status         as enum ('draft','published','cancelled','completed');
create type public.ticket_type          as enum ('rsvp','paid');
create type public.ticket_status        as enum ('going','waitlist','checked_in','cancelled');
create type public.report_subject       as enum ('user','event','community','message');
create type public.report_reason        as enum ('safety','harassment','spam','other');
create type public.report_status        as enum ('open','reviewed','actioned');

-- ─────────────────────────────────────────────────────────────── tables ─────

create table public.users (
  id                    uuid primary key references auth.users(id) on delete cascade,
  handle                text not null unique check (handle ~ '^[a-z0-9_]{3,30}$'),
  display_name          text not null check (char_length(display_name) between 1 and 50),
  avatar_url            text,          -- D2: nullable, no client write path until CSAM pipeline (Phase 3)
  bio                   text check (char_length(bio) <= 280),
  interests             text[] not null default '{}' check (cardinality(interests) <= 12),
  home_geohash          text check (home_geohash ~ '^[0123456789bcdefghjkmnpqrstuvwxyz]{1,5}$'),
  verification_status   public.verification_status not null default 'none',
  trust_score           integer not null default 0,
  profile_visibility    text not null default 'public' check (profile_visibility in ('public','private')),
  deletion_requested_at timestamptz,   -- 30-day grace marker; set only by delete_account Edge Function
  created_at            timestamptz not null default now()
);

create table public.spaces (
  id            uuid primary key default gen_random_uuid(),
  owner_user_id uuid references public.users(id) on delete set null,  -- nullable: claimed vs unclaimed
  name          text not null check (char_length(name) between 1 and 120),
  category      public.space_category not null,
  location      extensions.geography(point, 4326) not null,
  address       text not null,
  photos        text[] not null default '{}',
  amenities     text[] not null default '{}',
  hours         jsonb,
  capacity      integer check (capacity > 0),
  is_partner    boolean not null default false,
  rating_agg    numeric(3,2) check (rating_agg between 0 and 5),
  created_at    timestamptz not null default now()
);

create table public.communities (
  id            uuid primary key default gen_random_uuid(),
  creator_id    uuid not null references public.users(id) on delete restrict,
  name          text not null check (char_length(name) between 1 and 80),
  description   text check (char_length(description) <= 2000),
  cover_url     text,
  interest_tags text[] not null default '{}',
  visibility    public.community_visibility not null default 'public',
  member_count  integer not null default 0,  -- denormalized; maintained server-side only
  home_space_id uuid references public.spaces(id) on delete set null,
  created_at    timestamptz not null default now()
);

create table public.community_memberships (
  community_id          uuid not null references public.communities(id) on delete cascade,
  user_id               uuid not null references public.users(id) on delete cascade,
  role                  public.membership_role not null default 'member',
  tier                  public.membership_tier not null default 'newcomer',
  joined_at             timestamptz not null default now(),
  events_attended_count integer not null default 0,  -- driven by check-ins, server-side only
  primary key (community_id, user_id)
);

create table public.events (
  id              uuid primary key default gen_random_uuid(),
  community_id    uuid references public.communities(id) on delete set null,  -- nullable: standalone events
  host_id         uuid not null references public.users(id) on delete restrict,
  space_id        uuid not null references public.spaces(id) on delete restrict,
  title           text not null check (char_length(title) between 1 and 120),
  description     text check (char_length(description) <= 4000),
  cover_url       text,
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  recurrence_rule text,                -- RFC 5545 RRULE; validated in the Phase 3 creation Edge Function
  capacity        integer check (capacity > 0),
  price           integer not null default 0 check (price >= 0),  -- minor units; 0 = free
  status          public.event_status not null default 'draft',
  rsvp_count      integer not null default 0,  -- denormalized; maintained server-side only
  created_at      timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table public.tickets (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  user_id       uuid not null references public.users(id) on delete cascade,
  type          public.ticket_type not null default 'rsvp',
  status        public.ticket_status not null default 'going',
  qr_code_token text,                  -- signed short-TTL JWT; issued server-side (Phase 3)
  purchased_at  timestamptz not null default now(),
  checked_in_at timestamptz,
  unique (event_id, user_id)
);

create table public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references public.users(id) on delete cascade,  -- derived from JWT in submit_report
  subject_type public.report_subject not null,
  subject_id   uuid not null,
  reason       public.report_reason not null,
  detail       text check (char_length(detail) <= 500),
  status       public.report_status not null default 'open',
  created_at   timestamptz not null default now()
);

create table public.blocks (
  blocker_id uuid not null references public.users(id) on delete cascade,  -- derived from JWT in manage_block (D4)
  blocked_id uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  user_id    uuid,                     -- nullable: system events have no actor
  action     text not null,
  metadata   jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────── indexes ────

create index spaces_location_gix          on public.spaces using gist (location);
create index communities_visibility_idx   on public.communities (visibility);
create index memberships_user_idx         on public.community_memberships (user_id);
create index events_space_idx             on public.events (space_id);
create index events_community_idx         on public.events (community_id);
create index events_starts_at_idx         on public.events (starts_at) where status = 'published';
create index events_host_idx              on public.events (host_id);
create index tickets_event_idx            on public.tickets (event_id);
create index reports_subject_idx          on public.reports (subject_type, subject_id);
create index reports_reporter_idx         on public.reports (reporter_id);
create index blocks_blocked_idx           on public.blocks (blocked_id);  -- Phase 2 reverse-invisibility lookups
create index audit_log_user_idx           on public.audit_log (user_id, created_at);

-- ──────────────────────────────────── RLS: enable default-deny everywhere ───

alter table public.users                 enable row level security;
alter table public.spaces                enable row level security;
alter table public.communities           enable row level security;
alter table public.community_memberships enable row level security;
alter table public.events                enable row level security;
alter table public.tickets               enable row level security;
alter table public.reports               enable row level security;
alter table public.blocks                enable row level security;
alter table public.audit_log             enable row level security;

-- ──────────────────────────── privileges: revoke defaults, re-grant minimal ─

-- Supabase's default privileges grant ALL to anon/authenticated. Reset to zero
-- and grant back only what Phase 1 clients need, column-scoped where RLS
-- cannot express the restriction (RLS is row-level; grants are column-level).
revoke all on all tables in schema public from anon, authenticated;

grant select on public.users to authenticated;   -- rows limited to self by policy
grant insert (id, handle, display_name, bio, interests)
  on public.users to authenticated;
grant update (handle, display_name, bio, interests, home_geohash)
  on public.users to authenticated;
-- Deliberately not grantable to clients: avatar_url (D2), verification_status,
-- trust_score, profile_visibility (settings UI arrives Phase 2), deletion_requested_at.

grant select on public.spaces                to authenticated;
grant select on public.communities           to authenticated;
grant select on public.community_memberships to authenticated;
grant select on public.events                to authenticated;
grant select on public.tickets               to authenticated;
grant select on public.blocks                to authenticated;
grant insert (user_id, action, metadata) on public.audit_log to authenticated;
-- reports: zero grants to anon/authenticated — Edge Function (service_role) only.

-- audit_log immutability: insert-only for EVERY role, service_role included.
revoke update, delete on public.audit_log from anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────── policies ───

-- users: self only. Cross-user reads go through public_profiles (below).
create policy users_select_own on public.users for select
  using (auth.uid() = id);
create policy users_insert_own on public.users for insert
  with check (auth.uid() = id);
create policy users_update_own on public.users for update
  using (auth.uid() = id) with check (auth.uid() = id);

-- Public profile view: limited columns, definer semantics (bypasses users RLS
-- by design — this is the threat-model Layer 4 reference pattern). Excludes
-- accounts in the deletion grace window.
create view public.public_profiles
  with (security_invoker = off, security_barrier = true) as
  select id, handle, display_name, avatar_url, interests
  from public.users
  where profile_visibility = 'public'
    and deletion_requested_at is null;
grant select on public.public_profiles to authenticated;

-- spaces: venues are public content for signed-in users (Phase 2 Discover reads).
create policy spaces_select_authenticated on public.spaces for select
  to authenticated using (true);

-- communities: only 'public' visibility is listable in Phase 1/2.
-- (Member access to approval/private communities lands with Phase 3 membership flows.)
create policy communities_select_public on public.communities for select
  to authenticated using (visibility = 'public');

-- community_memberships: you see only your own memberships.
create policy memberships_select_own on public.community_memberships for select
  using (user_id = auth.uid());

-- events: only published events are visible to clients.
create policy events_select_published on public.events for select
  to authenticated using (status = 'published');

-- tickets: your own ticket, or you host the event (threat-model reference policy).
create policy tickets_select_own_or_host on public.tickets for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.events e
      where e.id = tickets.event_id and e.host_id = auth.uid()
    )
  );

-- blocks: read your own block list. No client writes — manage_block Edge Function only (D4).
create policy blocks_select_own on public.blocks for select
  using (blocker_id = auth.uid());

-- reports: no policies at all. Client access fully denied; submit_report Edge
-- Function (service_role, BYPASSRLS) is the only write path.

-- audit_log: clients may insert exactly the two consent events, as themselves.
-- No select/update/delete policies exist for clients; immutability enforced above.
create policy audit_insert_consent on public.audit_log for insert
  with check (
    user_id = auth.uid()
    and action in ('age_attestation', 'eula_accept')
  );

-- ─────────────────────────────── self-check: no table left without RLS ──────

do $$
declare r record;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
  loop
    raise exception 'GUARD VIOLATION: RLS disabled on public.%', r.relname;
  end loop;
end $$;
