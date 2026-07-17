-- ============================================================================
-- Thrd Spaces — migration 0005: blocked-user invisibility (task T18)
-- Non-negotiable guard: "Blocked users invisible in every list, feed, attendee
-- view, and channel." Threat-model Layer 7 (anti-stalking). Closes Phase 2
-- security-audit findings F1 (attendee_previews) and F1b (public_profiles);
-- decision D13 (widen to public_profiles) and D15 (nearby_events → DEFINER).
--
-- Bidirectional: if EITHER user blocked the other, each is invisible to the
-- other across public_profiles, attendee_previews, and nearby_events.
--
-- Mechanism — inlined `not exists` on public.blocks inside DEFINER objects:
-- the `blocks` RLS policy `blocks_select_own` (0001) exposes to a client only
-- rows where the caller is the *blocker*, so an INVOKER path can see only one
-- direction ("I blocked them") and never "they blocked me". Each object below
-- runs with its OWNER's privileges (postgres, which is not subject to the
-- client RLS on blocks), so its inlined subquery sees BOTH rows and enforces
-- both directions. The block rows themselves are never emitted — only filtered
-- result rows — so the manage_block invariant (the target cannot detect the
-- block) is preserved. (A shared SECURITY DEFINER helper was rejected: a view
-- checks function EXECUTE against the *invoking* role, so the helper would have
-- to be granted to clients, turning it into a "did X block me?" probe.)
--
-- `auth.uid()` resolves to the CALLER even under definer semantics — it reads
-- the request JWT claim, not the object owner.
--
-- Community listings are intentionally deferred to Phase 3 (D15): the only
-- Phase 2 community read (`communitiesMeetingAt` in Space Detail) is a
-- base-table RLS read with no definer path, and community discovery/listing is
-- a Phase 3 feature — the block filter lands with that consolidation (T26).
-- ============================================================================

-- ── public_profiles: exclude blocked pair (D13 / audit F1b) ─────────────────
create or replace view public.public_profiles
  with (security_invoker = off, security_barrier = true) as
  select id, handle, display_name, avatar_url, interests
  from public.users u
  where profile_visibility = 'public'
    and deletion_requested_at is null
    and not exists (
      select 1 from public.blocks bl
      where (bl.blocker_id = u.id and bl.blocked_id = auth.uid())
         or (bl.blocker_id = auth.uid() and bl.blocked_id = u.id)
    );
grant select on public.public_profiles to authenticated;

-- ── attendee_previews: exclude blocked pair (audit F1) ──────────────────────
create or replace view public.attendee_previews
  with (security_invoker = off, security_barrier = true) as
  select t.event_id,
         split_part(u.display_name, ' ', 1) as first_name,
         u.avatar_url
  from public.tickets t
  join public.users  u on u.id = t.user_id
  join public.events e on e.id = t.event_id
  where t.status = 'going'
    and e.status = 'published'
    and u.deletion_requested_at is null
    and not exists (
      select 1 from public.blocks bl
      where (bl.blocker_id = u.id and bl.blocked_id = auth.uid())
         or (bl.blocker_id = auth.uid() and bl.blocked_id = u.id)
    );
grant select on public.attendee_previews to authenticated;

-- ── nearby_events: events hosted by a blocked/blocking user vanish ──────────
-- INVOKER → DEFINER (D15). Required so the inlined block subquery sees both
-- directions (see header note). The visible row-set is PROVABLY unchanged by
-- the security-mode switch: the function already returned published events only
-- (`status = 'published'`, now a LOAD-BEARING security filter since RLS no
-- longer backs it) and all spaces are readable by every authenticated user
-- (`spaces_select_authenticated USING(true)`). The only behavioural change is
-- the new blocked-pair exclusion. `assert_geohash5` still runs (as owner).
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
language sql stable security definer
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
  where e.status = 'published'  -- LOAD-BEARING: RLS is bypassed under DEFINER
    and e.starts_at between now() and now() + least(horizon, interval '30 days')
    and extensions.st_dwithin(s.location, o.g, least(greatest(radius_m, 100), 10000))
    and not exists (
      select 1 from public.blocks bl
      where (bl.blocker_id = e.host_id and bl.blocked_id = auth.uid())
         or (bl.blocker_id = auth.uid() and bl.blocked_id = e.host_id)
    )
  order by distance_meters, e.starts_at;
$$;

-- Re-assert ownership + the authenticated-only surface (unchanged from 0003).
alter function public.nearby_events(text, integer, interval) owner to postgres;
revoke all on function public.nearby_events(text, integer, interval) from public, anon;
grant execute on function public.nearby_events(text, integer, interval) to authenticated;
