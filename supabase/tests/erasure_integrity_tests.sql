-- ============================================================================
-- Thrd Spaces — erasure-integrity test suite (Phase 3, task T22 / migration 0006)
-- Decision D12; closes Phase-2 audit findings F3 (incomplete erasure) + F10
-- (silent skips). Proves purge_deleted_accounts fully erases a user who hosts
-- events and created communities (the D11 RESTRICT landmine), with correct DPDP
-- segmentation and a complete uuid re-key.
--
-- Runs as the DB owner (purge_deleted_accounts is SECURITY DEFINER owner
-- postgres), in one transaction that rolls back — leaves no state:
--   psql "$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2- | tr -d '\"')" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/erasure_integrity_tests.sql
--
-- P = purged user (host + community creator, past the 30-day grace). Q = survivor.
-- ============================================================================
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('aaaaaaaa-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p@t.local','x',now(),now()),
  ('bbbbbbbb-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','q@t.local','x',now(),now());
insert into public.users (id, handle, display_name, deletion_requested_at) values
  ('aaaaaaaa-0000-0000-0000-000000000001','user_p','User P', now() - interval '35 days'),
  ('bbbbbbbb-0000-0000-0000-000000000002','user_q','User Q', null);

insert into public.spaces (id, name, category, location, address) values
  ('cccccccc-0000-0000-0000-000000000003','Cafe','cafe', extensions.st_point(77.59,12.97)::extensions.geography,'BLR');

-- P-hosted events: draft (delete), completed (retain, host→null),
-- future-cancelled w/ no other attendee (delete), future-cancelled w/ Q going (retain).
insert into public.events (id, host_id, space_id, title, starts_at, ends_at, status) values
  ('e0000000-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000003','Draft',    now()+interval '3 days', now()+interval '3 days 2h','draft'),
  ('e0000000-0000-0000-0000-0000000000c2','aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000003','Completed', now()-interval '3 days', now()-interval '3 days' + interval '2h','completed'),
  ('e0000000-0000-0000-0000-0000000000c3','aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000003','CancNoAtt', now()+interval '3 days', now()+interval '3 days 2h','cancelled'),
  ('e0000000-0000-0000-0000-0000000000c4','aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000003','CancQAtt',  now()+interval '3 days', now()+interval '3 days 2h','cancelled');
insert into public.tickets (event_id, user_id, status) values
  ('e0000000-0000-0000-0000-0000000000c4','bbbbbbbb-0000-0000-0000-000000000002','going');

insert into public.communities (id, creator_id, name, visibility) values
  ('f0000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001','Sole','public'),
  ('f0000000-0000-0000-0000-0000000000a2','aaaaaaaa-0000-0000-0000-000000000001','Multi','public');
insert into public.community_memberships (community_id, user_id, role) values
  ('f0000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001','host'),
  ('f0000000-0000-0000-0000-0000000000a2','aaaaaaaa-0000-0000-0000-000000000001','host'),
  ('f0000000-0000-0000-0000-0000000000a2','bbbbbbbb-0000-0000-0000-000000000002','member');

insert into public.reports (reporter_id, subject_type, subject_id, reason) values
  ('bbbbbbbb-0000-0000-0000-000000000002','user','aaaaaaaa-0000-0000-0000-000000000001','spam'),  -- about P → erase
  ('aaaaaaaa-0000-0000-0000-000000000001','user','bbbbbbbb-0000-0000-0000-000000000002','spam');  -- by P → cascade

insert into public.audit_log (user_id, action, metadata) values
  ('aaaaaaaa-0000-0000-0000-000000000001','signup','{}'::jsonb),
  ('bbbbbbbb-0000-0000-0000-000000000002','report_submit', jsonb_build_object('subject_id','aaaaaaaa-0000-0000-0000-000000000001')),
  ('bbbbbbbb-0000-0000-0000-000000000002','block', jsonb_build_object('target','aaaaaaaa-0000-0000-0000-000000000001'));

select public.purge_deleted_accounts() as purged;

do $$
declare n int; h text;
begin
  -- Core D11 fix: a host + community creator is fully purged (no RESTRICT throw).
  perform 1 from auth.users where id='aaaaaaaa-0000-0000-0000-000000000001';
  if found then raise exception 'FAIL: P (host+creator) not deleted — RESTRICT landmine still live'; end if;
  perform 1 from public.users where id='bbbbbbbb-0000-0000-0000-000000000002';
  if not found then raise exception 'FAIL: survivor Q wrongly deleted'; end if;

  -- DPDP segmentation: sole-owner no-counterparty content DELETED.
  perform 1 from public.events where id='e0000000-0000-0000-0000-0000000000d1';
  if found then raise exception 'FAIL: draft event retained (should erase)'; end if;
  perform 1 from public.events where id='e0000000-0000-0000-0000-0000000000c3';
  if found then raise exception 'FAIL: cancelled-no-attendee event retained (should erase)'; end if;
  perform 1 from public.communities where id='f0000000-0000-0000-0000-0000000000a1';
  if found then raise exception 'FAIL: sole-member community retained (should erase)'; end if;

  -- Counterparty rows RETAINED with owner nulled (defensible retention).
  select host_id into h from public.events where id='e0000000-0000-0000-0000-0000000000c2';
  if not found then raise exception 'FAIL: completed event wrongly deleted'; end if;
  if h is not null then raise exception 'FAIL: completed event host_id not nulled'; end if;
  select host_id into h from public.events where id='e0000000-0000-0000-0000-0000000000c4';
  if not found then raise exception 'FAIL: cancelled-with-attendee event wrongly deleted'; end if;
  if h is not null then raise exception 'FAIL: retained cancelled event host_id not nulled'; end if;
  select creator_id into h from public.communities where id='f0000000-0000-0000-0000-0000000000a2';
  if not found then raise exception 'FAIL: multi-member community wrongly deleted'; end if;
  if h is not null then raise exception 'FAIL: multi-member community creator_id not nulled'; end if;

  -- Reports: subject-P erased (no FK, would survive); reporter-P cascaded.
  select count(*) into n from public.reports where subject_id='aaaaaaaa-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL: report about P not erased (% rows)', n; end if;
  select count(*) into n from public.reports where reporter_id='aaaaaaaa-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL: report by P not cascaded (% rows)', n; end if;

  -- COMPLETE re-key (F3): P's uuid survives in NO audit column.
  select count(*) into n from public.audit_log
   where user_id='aaaaaaaa-0000-0000-0000-000000000001'
      or metadata->>'subject_id'='aaaaaaaa-0000-0000-0000-000000000001'
      or metadata->>'target'='aaaaaaaa-0000-0000-0000-000000000001';
  if n <> 0 then raise exception 'FAIL: P uuid survives in audit_log (% rows) — erasure incomplete', n; end if;
  select count(*) into n from public.audit_log where metadata ? 'purged_user';
  if n < 1 then raise exception 'FAIL: no purged_user hash written (re-key did not run)'; end if;

  -- F10: durable summary with the skipped counter.
  select count(*) into n from public.audit_log where action='purge_run' and metadata ? 'skipped';
  if n <> 1 then raise exception 'FAIL: purge_run summary missing/malformed (% rows)', n; end if;

  raise notice 'ALL ERASURE-INTEGRITY TESTS PASSED';
end $$;

rollback;
