-- ============================================================================
-- Thrd Spaces — 0003_geo_reads.sql (Phase 2, task T12)
-- The Phase 2 discovery read layer, per decisions D6–D8:
--   * nearby_spaces / nearby_events RPCs — the ONLY location-query surface.
--     Input is a geohash-5 CELL id (user coords are snapped on-device; the
--     server accepts nothing finer — D8). Venue pins return exact (public
--     places). Radius hard-capped server-side.
--   * attendee_previews view — PRD social proof under the attendee-list
--     privacy guard: first name + avatar only, going tickets on published
--     events. (Blocked-pair exclusion lands in 0005/T18.)
--   * spaces.source_ref — seed provenance (D7), zero client visibility.
--   * events_select_own_drafts policy + profile_visibility UPDATE grant
--     (Artifact A PLANNED → MIGRATED).
-- ============================================================================

-- ─────────────────────────────────────────────── spaces.source_ref (D7) ─────

alter table public.spaces add column source_ref text;
comment on column public.spaces.source_ref is
  'Seed provenance, e.g. osm:node/123 (D7). Admin/seed-script only; no client grants.';
create unique index spaces_source_ref_uidx on public.spaces (source_ref)
  where source_ref is not null;  -- idempotent seed re-runs

-- The 0001 SELECT grant on spaces was table-level, which would expose the new
-- column. Re-grant column-scoped, excluding source_ref.
revoke select on public.spaces from authenticated;
grant select (id, owner_user_id, name, category, location, address, photos,
              amenities, hours, capacity, is_partner, rating_agg, created_at)
  on public.spaces to authenticated;

-- ───────────────────────────── Artifact A planned policies, now migrated ────

-- Hosts read their own drafts (policies OR together with events_select_published).
create policy events_select_own_drafts on public.events for select
  using (host_id = auth.uid());

-- Privacy settings screen (Phase 2) may flip profile visibility on own row.
grant update (profile_visibility) on public.users to authenticated;

-- ─────────────────────────────────────────────── attendee_previews view ─────
-- Social proof for event detail (PRD §3) under the attendee-list-privacy
-- guard: FIRST NAME + avatar only — no handle, no id linkage beyond what the
-- avatar itself reveals, no private-profile distinction (attending a published
-- event is a public act; documented in Artifact A). Definer semantics like
-- public_profiles. 0005 (T18) adds blocked-pair exclusion.
create view public.attendee_previews
  with (security_invoker = off, security_barrier = true) as
  select t.event_id,
         split_part(u.display_name, ' ', 1) as first_name,
         u.avatar_url
  from public.tickets t
  join public.users  u on u.id = t.user_id
  join public.events e on e.id = t.event_id
  where t.status = 'going'
    and e.status = 'published'
    and u.deletion_requested_at is null;
grant select on public.attendee_previews to authenticated;

-- ───────────────────────────────────────────────────── geo RPCs (D8) ────────
-- SECURITY INVOKER: results ride on the caller's own RLS/grants (spaces are
-- readable, only published events are visible). Input validation is the
-- coarsening boundary: exactly a 5-char geohash cell, nothing finer.

create or replace function public.assert_geohash5(cell text)
returns extensions.geometry
language plpgsql immutable
as $$
begin
  if cell !~ '^[0123456789bcdefghjkmnpqrstuvwxyz]{5}$' then
    raise exception 'invalid_cell' using errcode = '22023';
  end if;
  return extensions.st_pointfromgeohash(cell);
end;
$$;

create or replace function public.nearby_spaces(cell text, radius_m integer default 5000)
returns table (
  id uuid, owner_user_id uuid, name text, category public.space_category,
  latitude double precision, longitude double precision,
  address text, photos text[], amenities text[], hours jsonb,
  capacity integer, is_partner boolean, rating_agg numeric,
  created_at timestamptz,
  distance_meters integer, upcoming_event_count integer
)
language sql stable security invoker
set search_path = public, extensions, pg_temp
as $$
  with origin as (
    select public.assert_geohash5(cell)::extensions.geography as g
  )
  select s.id, s.owner_user_id, s.name, s.category,
         extensions.st_y(s.location::extensions.geometry) as latitude,
         extensions.st_x(s.location::extensions.geometry) as longitude,
         s.address, s.photos, s.amenities, s.hours,
         s.capacity, s.is_partner, s.rating_agg, s.created_at,
         extensions.st_distance(s.location, o.g)::integer as distance_meters,
         (select count(*)::integer from public.events e
           where e.space_id = s.id and e.status = 'published'
             and e.starts_at > now()) as upcoming_event_count
  from public.spaces s, origin o
  where extensions.st_dwithin(s.location, o.g, least(greatest(radius_m, 100), 10000))
  order by distance_meters;
$$;

create or replace function public.nearby_events(
  cell text, radius_m integer default 5000, horizon interval default interval '7 days'
)
returns table (
  id uuid, community_id uuid, host_id uuid, space_id uuid,
  title text, description text, cover_url text,
  starts_at timestamptz, ends_at timestamptz, recurrence_rule text,
  capacity integer, price integer, status public.event_status,
  rsvp_count integer, created_at timestamptz,
  venue_name text, latitude double precision, longitude double precision,
  distance_meters integer
)
language sql stable security invoker
set search_path = public, extensions, pg_temp
as $$
  with origin as (
    select public.assert_geohash5(cell)::extensions.geography as g
  )
  select e.id, e.community_id, e.host_id, e.space_id,
         e.title, e.description, e.cover_url,
         e.starts_at, e.ends_at, e.recurrence_rule,
         e.capacity, e.price, e.status, e.rsvp_count, e.created_at,
         s.name as venue_name,
         extensions.st_y(s.location::extensions.geometry) as latitude,
         extensions.st_x(s.location::extensions.geometry) as longitude,
         extensions.st_distance(s.location, o.g)::integer as distance_meters
  from public.events e
  join public.spaces s on s.id = e.space_id, origin o
  where e.status = 'published'
    and e.starts_at between now() and now() + least(horizon, interval '30 days')
    and extensions.st_dwithin(s.location, o.g, least(greatest(radius_m, 100), 10000))
  order by distance_meters, e.starts_at;
$$;

-- Lock the RPC surface: authenticated only (no anon discovery in Phase 2).
-- assert_geohash5 needs authenticated EXECUTE because the nearby_* functions
-- are SECURITY INVOKER — the helper runs as the caller. It is pure validation
-- (no data access), so this grants nothing sensitive.
revoke all on function public.assert_geohash5(text) from public, anon;
revoke all on function public.nearby_spaces(text, integer) from public, anon;
revoke all on function public.nearby_events(text, integer, interval) from public, anon;
grant execute on function public.assert_geohash5(text) to authenticated;
grant execute on function public.nearby_spaces(text, integer) to authenticated;
grant execute on function public.nearby_events(text, integer, interval) to authenticated;

-- ───────────────────────────────────────────────────────────── indexes ──────

create index events_space_status_starts_idx
  on public.events (space_id, status, starts_at);

-- ─────────────────────────────── self-check: RLS still on every table ───────

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
