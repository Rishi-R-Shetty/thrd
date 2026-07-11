-- ============================================================================
-- Thrd Spaces — RLS hostile-user test suite (Phase 1, task T3)
-- Guard under test: "RLS on every Supabase table, default-deny, tested with a
-- hostile-user assertion."
--
-- Run against a local stack with the migration applied:
--   psql "$(supabase status -o env | grep DB_URL | cut -d= -f2-)" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/rls_hostile_user_tests.sql
--
-- The whole suite runs in one transaction and rolls back — it leaves no state.
-- Every assertion raises an exception on failure; a clean exit means PASS.
-- Convention: user A (attacker) = 11111111-…, user B (victim) = 22222222-….
-- ============================================================================

begin;

-- ── seed (as postgres, bypassing RLS) ───────────────────────────────────────

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'a@test.local', 'x', now(), now()),
  ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'b@test.local', 'x', now(), now());

insert into public.users (id, handle, display_name, bio, profile_visibility) values
  ('11111111-1111-1111-1111-111111111111', 'user_a', 'User A', null, 'public'),
  ('22222222-2222-2222-2222-222222222222', 'user_b', 'User B', 'private bio', 'private');

insert into public.spaces (id, name, category, location, address) values
  ('33333333-3333-3333-3333-333333333333', 'Test Cafe', 'cafe',
   extensions.st_point(77.5946, 12.9716)::extensions.geography, 'Bengaluru');

insert into public.communities (id, creator_id, name, visibility) values
  ('44444444-4444-4444-4444-444444444401', '22222222-2222-2222-2222-222222222222', 'B Public Club', 'public'),
  ('44444444-4444-4444-4444-444444444402', '22222222-2222-2222-2222-222222222222', 'B Private Club', 'private');

insert into public.community_memberships (community_id, user_id, role) values
  ('44444444-4444-4444-4444-444444444401', '22222222-2222-2222-2222-222222222222', 'host');

insert into public.events (id, host_id, space_id, title, starts_at, ends_at, status) values
  ('55555555-5555-5555-5555-555555555501', '22222222-2222-2222-2222-222222222222',
   '33333333-3333-3333-3333-333333333333', 'B published event', now() + interval '1 day', now() + interval '1 day 2 hours', 'published'),
  ('55555555-5555-5555-5555-555555555502', '22222222-2222-2222-2222-222222222222',
   '33333333-3333-3333-3333-333333333333', 'B draft event', now() + interval '2 days', now() + interval '2 days 2 hours', 'draft');

insert into public.tickets (id, event_id, user_id) values
  ('66666666-6666-6666-6666-666666666601', '55555555-5555-5555-5555-555555555501',
   '22222222-2222-2222-2222-222222222222');

insert into public.reports (reporter_id, subject_type, subject_id, reason) values
  ('22222222-2222-2222-2222-222222222222', 'user', '11111111-1111-1111-1111-111111111111', 'spam');

insert into public.blocks (blocker_id, blocked_id) values
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111');

insert into public.audit_log (user_id, action) values
  ('22222222-2222-2222-2222-222222222222', 'signup');

-- ── become hostile user A ───────────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims to
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","aud":"authenticated"}';

-- helper expectations run as DO blocks; each raises on failure.

-- [users] A sees exactly one users row: their own.
do $$
declare n int;
begin
  select count(*) into n from public.users;
  if n <> 1 then raise exception 'FAIL users-read: A sees % rows, expected 1 (own)', n; end if;
  perform 1 from public.users where id <> auth.uid();
  if found then raise exception 'FAIL users-read: A can read another user''s base row'; end if;
end $$;

-- [users] A cannot UPDATE B's row (0 rows affected — RLS filters it).
do $$
declare n int;
begin
  update public.users set display_name = 'pwned'
  where id = '22222222-2222-2222-2222-222222222222';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL users-write: A updated B''s profile (% rows)', n; end if;
end $$;

-- [users] A cannot escalate own authorization fields (column grant denies).
do $$
begin
  begin
    update public.users set verification_status = 'id_verified' where id = auth.uid();
    raise exception 'FAIL users-escalate: A set own verification_status';
  exception when insufficient_privilege then null; -- expected
  end;
  begin
    update public.users set trust_score = 9999 where id = auth.uid();
    raise exception 'FAIL users-escalate: A set own trust_score';
  exception when insufficient_privilege then null; -- expected
  end;
  begin
    update public.users set avatar_url = 'https://evil.example/x.png' where id = auth.uid();
    raise exception 'FAIL users-escalate: A wrote avatar_url (D2: no client write path)';
  exception when insufficient_privilege then null; -- expected
  end;
end $$;

-- [users] A cannot INSERT a row for an id that is not their own JWT sub.
do $$
begin
  insert into public.users (id, handle, display_name)
  values ('99999999-9999-9999-9999-999999999999', 'ghost', 'Ghost');
  raise exception 'FAIL users-insert: A created a row for a foreign id';
exception
  when insufficient_privilege then null;         -- RLS with-check
  when check_violation then null;
  when sqlstate '42501' then null;
  when foreign_key_violation then
    raise exception 'FAIL users-insert: reached FK check — RLS with_check did not fire first';
end $$;

-- [public_profiles] A sees only public, non-deleting profiles; limited columns.
do $$
declare n int;
begin
  select count(*) into n from public.public_profiles
  where id = '22222222-2222-2222-2222-222222222222';
  if n <> 0 then raise exception 'FAIL profiles: B is profile_visibility=private but visible'; end if;
end $$;

-- [communities] private community invisible; public one visible.
do $$
declare n int;
begin
  select count(*) into n from public.communities where visibility = 'private';
  if n <> 0 then raise exception 'FAIL communities: A sees a private community'; end if;
  select count(*) into n from public.communities where id = '44444444-4444-4444-4444-444444444401';
  if n <> 1 then raise exception 'FAIL communities: public community not visible'; end if;
end $$;

-- [community_memberships] A sees no one else's memberships.
do $$
declare n int;
begin
  select count(*) into n from public.community_memberships;
  if n <> 0 then raise exception 'FAIL memberships: A sees % foreign membership rows', n; end if;
end $$;

-- [events] drafts invisible; published visible.
do $$
declare n int;
begin
  select count(*) into n from public.events where status <> 'published';
  if n <> 0 then raise exception 'FAIL events: A sees a non-published event'; end if;
  select count(*) into n from public.events where id = '55555555-5555-5555-5555-555555555501';
  if n <> 1 then raise exception 'FAIL events: published event not visible'; end if;
end $$;

-- [events] A cannot publish/steal an event (no update grant at all).
do $$
begin
  update public.events set status = 'published'
  where id = '55555555-5555-5555-5555-555555555502';
  raise exception 'FAIL events-write: A updated an event';
exception when insufficient_privilege then null; -- expected: no UPDATE grant
end $$;

-- [tickets] A is not host and holds no ticket → sees nothing (attendee-list privacy).
do $$
declare n int;
begin
  select count(*) into n from public.tickets;
  if n <> 0 then raise exception 'FAIL tickets: A sees % foreign tickets', n; end if;
end $$;

-- [tickets] A cannot forge a ticket (no INSERT grant in Phase 1).
do $$
begin
  insert into public.tickets (event_id, user_id)
  values ('55555555-5555-5555-5555-555555555501', auth.uid());
  raise exception 'FAIL tickets-write: A inserted a ticket directly';
exception when insufficient_privilege then null; -- expected
end $$;

-- [reports] fully invisible and unwritable from the client (Edge Function only).
do $$
declare n int;
begin
  select count(*) into n from public.reports;
  if n <> 0 then raise exception 'FAIL reports: A sees % report rows (should be 0 — B''s report about A must never leak)', n; end if;
exception when insufficient_privilege then null; -- also acceptable: no SELECT grant at all
end $$;
do $$
begin
  insert into public.reports (reporter_id, subject_type, subject_id, reason)
  values (auth.uid(), 'user', '22222222-2222-2222-2222-222222222222', 'spam');
  raise exception 'FAIL reports-write: A inserted a report directly (must go through submit_report)';
exception when insufficient_privilege then null; -- expected
end $$;

-- [blocks] A cannot see B's block of A (blocked-user invisibility of the block itself).
do $$
declare n int;
begin
  select count(*) into n from public.blocks;
  if n <> 0 then raise exception 'FAIL blocks: A can see that B blocked A'; end if;
end $$;

-- [blocks] A cannot write blocks directly (D4: manage_block Edge Function only).
do $$
begin
  insert into public.blocks (blocker_id, blocked_id)
  values (auth.uid(), '22222222-2222-2222-2222-222222222222');
  raise exception 'FAIL blocks-write: A inserted a block directly';
exception when insufficient_privilege then null; -- expected
end $$;

-- [audit_log] invisible to clients; A can log own consent events only; immutable.
do $$
declare n int;
begin
  begin
    select count(*) into n from public.audit_log;
    if n <> 0 then raise exception 'FAIL audit-read: A sees % audit rows', n; end if;
  exception when insufficient_privilege then null; -- no SELECT grant: fine
  end;
end $$;
do $$
begin
  insert into public.audit_log (user_id, action) values (auth.uid(), 'eula_accept'); -- allowed
  begin
    insert into public.audit_log (user_id, action)
    values ('22222222-2222-2222-2222-222222222222', 'eula_accept');
    raise exception 'FAIL audit-forge: A logged an event as B';
  exception when insufficient_privilege then null; when check_violation then null;
  end;
  begin
    insert into public.audit_log (user_id, action) values (auth.uid(), 'ban_action');
    raise exception 'FAIL audit-forge: A logged a non-consent action';
  exception when insufficient_privilege then null; when check_violation then null;
  end;
end $$;

-- [anon] signed-out client sees nothing anywhere.
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';
do $$
declare t text; n int;
begin
  foreach t in array array['users','spaces','communities','community_memberships',
                           'events','tickets','reports','blocks','audit_log']
  loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      if n <> 0 then raise exception 'FAIL anon: % rows visible in %', n, t; end if;
    exception when insufficient_privilege then null; -- no grant at all: even better
    end;
  end loop;
end $$;

reset role;
select 'ALL HOSTILE-USER TESTS PASSED' as result;

rollback;
