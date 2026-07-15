-- ============================================================================
-- Thrd Spaces — 0004_rsvp_support.sql (Phase 2, task T16)
-- Backing schema for Artifact B §4 (rsvp_event) and §5 (purge_deleted_accounts).
--
--   * rsvp_event_tx  — the transactional core of rsvp_event. SELECT … FOR UPDATE
--     on the event row decides capacity/waitlist server-side; the Edge Function
--     never trusts a client count. SECURITY INVOKER: runs as service_role under
--     the minimal column-scoped grants below (D5), so it is a transaction
--     boundary, not a second authorization layer.
--   * service_role grants — tickets SELECT/INSERT/UPDATE (columns only),
--     events SELECT + UPDATE(rsvp_count), users SELECT(verification_status),
--     per D5. No client (anon/authenticated) grant is added anywhere.
--   * purge_deleted_accounts() — SECURITY DEFINER, OWNER postgres. The SOLE
--     documented exception to audit_log immutability: it re-keys purged users'
--     audit rows (UPDATE), which every role below the owner has revoked. Driven
--     by pg_cron (no HTTP caller), so it is a SQL function, not an Edge Function.
--   * pg_cron schedule at 22:00 UTC = 03:30 IST (Artifact B §5).
--   * feature_flags seed row `fn:purge_deleted_accounts` (kill switch).
--   * waitlist-order index on tickets.
--
-- audit_log stays insert-only for every role EXCEPT the postgres-owned purge
-- function (0001/0002 revokes preserved). No RLS policy is added or changed.
-- ============================================================================

-- ─────────────────────────────────── service_role grants for rsvp_event (D5) ─
-- rsvp_event_tx runs SECURITY INVOKER as service_role (BYPASSRLS handles RLS;
-- column grants are still required under the not-auto-exposed Data API default).

-- events: read the fields the capacity decision needs; write only the count.
-- (0001 granted table-level SELECT on events to `authenticated`, never to
-- service_role — add the minimal column-scoped read + the count write here.)
grant select (id, status, starts_at, price, capacity, rsvp_count)
  on public.events to service_role;
grant update (rsvp_count) on public.events to service_role;

-- users: read verification_status for the tier-0 cap. (0002 already granted
-- service_role SELECT(id, deletion_requested_at); this adds one more column.)
grant select (verification_status) on public.users to service_role;

-- tickets: the only write path in Phase 2. SELECT covers the own-ticket lookup
-- and the waitlist-head scan; INSERT the new RSVP; UPDATE the status changes
-- (cancel, promote, re-RSVP of a previously cancelled row) + re-queue timestamp.
grant select (id, event_id, user_id, status, purchased_at)
  on public.tickets to service_role;
grant insert (event_id, user_id, status) on public.tickets to service_role;
grant update (status, purchased_at)      on public.tickets to service_role;

-- ──────────────────────────────────────────── waitlist-order supporting index ─
-- promote-oldest query: WHERE event_id = ? AND status = 'waitlist'
--                       ORDER BY purchased_at ASC LIMIT 1.
create index tickets_event_status_purchased_idx
  on public.tickets (event_id, status, purchased_at);

-- ───────────────────────────────────────────────────── rsvp_event_tx (§4) ────
-- One transaction. The FOR UPDATE lock on the event row serializes concurrent
-- callers, so the last-seat race resolves to exactly one `going` and, for the
-- loser, one `waitlist`. Returns a discriminated jsonb the function maps to
-- stable HTTP codes — no schema/SQL detail crosses the boundary.
create or replace function public.rsvp_event_tx(
  p_event_id uuid,
  p_user_id  uuid,
  p_action   text
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_status     public.event_status;
  v_starts_at  timestamptz;
  v_price      integer;
  v_capacity   integer;
  v_count      integer;
  v_vs         public.verification_status;
  v_ticket_id  uuid;
  v_ticket_st  public.ticket_status;
  v_new_status public.ticket_status;
  v_promoted   uuid;
begin
  -- Lock the event row for the duration of this transaction. A concurrent
  -- caller for the same event blocks here until we commit, then reads the
  -- count we wrote — this is what makes the capacity decision race-free.
  select status, starts_at, price, capacity, rsvp_count
    into v_status, v_starts_at, v_price, v_capacity, v_count
    from public.events
   where id = p_event_id
     for update;

  -- Unknown id and drafts are indistinguishable to the caller (no draft-
  -- existence oracle): both return not_found.
  if not found or v_status = 'draft' then
    return jsonb_build_object('result', 'not_found');
  end if;

  -- Anything other than a future, free, published event is "not open".
  -- cancelled/completed were once public, so event_not_open leaks no new fact;
  -- a draft never was, hence the not_found above.
  if v_status <> 'published'
     or v_starts_at <= now()
     or v_price > 0 then
    return jsonb_build_object('result', 'event_not_open');
  end if;

  -- Tier-0 cap (threat-model Layer 3), read server-side: an unverified caller
  -- may RSVP only to free events with capacity ≤ 20. Unlimited (capacity NULL)
  -- counts as > 20. Applies to the rsvp action only — never blocks a cancel.
  if p_action = 'rsvp' then
    select verification_status into v_vs
      from public.users where id = p_user_id;
    if v_vs = 'none' and (v_capacity is null or v_capacity > 20) then
      return jsonb_build_object('result', 'verification_required');
    end if;
  end if;

  -- Own ticket (if any), locked. unique(event_id,user_id) means at most one.
  select id, status into v_ticket_id, v_ticket_st
    from public.tickets
   where event_id = p_event_id and user_id = p_user_id
     for update;

  if p_action = 'rsvp' then
    -- Active ticket → idempotent: return the current state unchanged.
    if v_ticket_id is not null
       and v_ticket_st in ('going', 'waitlist', 'checked_in') then
      return jsonb_build_object(
        'result', 'ok', 'status', v_ticket_st, 'rsvp_count', v_count);
    end if;

    -- Seat available → going (and increment); otherwise waitlist.
    if v_capacity is null or v_count < v_capacity then
      v_new_status := 'going';
    else
      v_new_status := 'waitlist';
    end if;

    if v_ticket_id is not null then
      -- Re-RSVP of a previously cancelled row (unique constraint forbids a
      -- second insert). Reset purchased_at → back of the waitlist queue.
      update public.tickets
         set status = v_new_status, purchased_at = now()
       where id = v_ticket_id;
    else
      insert into public.tickets (event_id, user_id, status)
      values (p_event_id, p_user_id, v_new_status);
    end if;

    if v_new_status = 'going' then
      update public.events set rsvp_count = rsvp_count + 1
       where id = p_event_id
      returning rsvp_count into v_count;
    end if;

    return jsonb_build_object(
      'result', 'ok', 'status', v_new_status, 'rsvp_count', v_count);

  else  -- p_action = 'cancel'
    -- No active ticket → idempotent cancelled; count unchanged.
    if v_ticket_id is null or v_ticket_st = 'cancelled' then
      return jsonb_build_object(
        'result', 'ok', 'status', 'cancelled', 'rsvp_count', v_count);
    end if;

    update public.tickets set status = 'cancelled' where id = v_ticket_id;

    -- Only a `going` seat frees capacity. Promote the oldest waitlist ticket if
    -- one exists (net count unchanged); otherwise decrement.
    if v_ticket_st = 'going' then
      select id into v_promoted
        from public.tickets
       where event_id = p_event_id and status = 'waitlist'
       order by purchased_at asc
       limit 1
         for update skip locked;

      if v_promoted is not null then
        update public.tickets set status = 'going' where id = v_promoted;
        -- rsvp_count unchanged: one going left, one waitlist promoted in.
      else
        update public.events set rsvp_count = rsvp_count - 1
         where id = p_event_id
        returning rsvp_count into v_count;
      end if;
    end if;

    return jsonb_build_object(
      'result', 'ok', 'status', 'cancelled', 'rsvp_count', v_count);
  end if;
end;
$$;

-- Clients never call the transaction directly — service_role (the Edge
-- Function) only. authenticated/anon get nothing.
revoke all on function public.rsvp_event_tx(uuid, uuid, text) from public;
grant execute on function public.rsvp_event_tx(uuid, uuid, text) to service_role;

-- Kill switch for the Edge Function (0002 seeds one row per function; the
-- envelope treats a missing row as enabled, so this row is what makes the
-- switch flippable from the dashboard without a deploy).
insert into public.feature_flags (key, enabled) values ('fn:rsvp_event', true)
on conflict (key) do nothing;

-- ═══════════════════════════ purge_deleted_accounts (§5) ════════════════════

-- Pepper for the one-way re-key of purged users' audit rows. Lives in Vault, so
-- no plaintext secret enters the repo. Seeded idempotently with a fresh random
-- value only if absent — production may pre-seed its own via vault.create_secret
-- before the first run and this will not overwrite it (mirrors THRD_JWT_SECRET
-- being set per environment). The purge fails closed if the pepper is missing.
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'purge_pepper') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'purge_pepper',
      'Server pepper for sha256 re-key of purged users'' audit rows (Artifact B §5).'
    );
  end if;
end $$;

-- Kill switch for the job (checked at entry, Artifact B §5).
insert into public.feature_flags (key, enabled)
values ('fn:purge_deleted_accounts', true)
on conflict (key) do nothing;

-- Completes delete_account's 30-day grace. OWNER postgres + SECURITY DEFINER is
-- the sole audit_log-immutability exception: re-keying needs UPDATE, revoked
-- from every role below the owner. No other path runs as owner.
create or replace function public.purge_deleted_accounts()
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_enabled boolean;
  v_pepper  text;
  v_uid     uuid;
  v_purged  integer := 0;
begin
  -- Kill switch. Missing row = enabled (disabling is opt-in), matching the
  -- Edge envelope's semantics.
  select enabled into v_enabled from public.feature_flags
   where key = 'fn:purge_deleted_accounts';
  if v_enabled is not null and v_enabled = false then
    raise notice 'purge_deleted_accounts: disabled by kill switch';
    return 0;
  end if;

  -- Fail closed without a pepper — re-keying to a guessable value is worse than
  -- not purging (the grace predicate keeps the user eligible for the next run).
  select decrypted_secret into v_pepper from vault.decrypted_secrets
   where name = 'purge_pepper';
  if v_pepper is null then
    raise exception 'purge_deleted_accounts: missing purge_pepper secret';
  end if;

  for v_uid in
    select id from public.users
     where deletion_requested_at < now() - interval '30 days'
  loop
    -- Per-user re-key + delete in ONE subtransaction: on any error both roll
    -- back, so we NEVER re-key a user we could not delete. A failure (e.g. a
    -- RESTRICT FK from a hosted event) leaves the user eligible for retry and
    -- is logged, without aborting the whole run.
    begin
      -- (1) Scrub the uuid from this user's audit rows, recording only a
      -- salted one-way hash for legal retention. audit_log.user_id has no FK,
      -- so these rows survive the cascade below — hence the explicit re-key.
      update public.audit_log
         set user_id = null,
             metadata = metadata || jsonb_build_object(
               'purged_user',
               encode(extensions.digest(v_uid::text || v_pepper, 'sha256'), 'hex'))
       where user_id = v_uid;

      -- (2) Hard-delete PII. Cascades to public.users → tickets, memberships,
      -- blocks (both directions), reports.
      delete from auth.users where id = v_uid;

      v_purged := v_purged + 1;
    exception when others then
      raise notice 'purge_deleted_accounts: user % skipped (%).', v_uid, sqlerrm;
    end;
  end loop;

  -- (3) One summary row (system event → user_id NULL).
  insert into public.audit_log (user_id, action, metadata)
  values (null, 'purge_run', jsonb_build_object('purged', v_purged));

  return v_purged;
end;
$$;

-- Owner must be postgres for the immutability exception to hold. (Local reset
-- runs migrations as postgres already; assert it explicitly for any environment
-- that does not.)
alter function public.purge_deleted_accounts() owner to postgres;

-- Only the cron scheduler (running as postgres) invokes it. No client, and not
-- even service_role, may call the re-key path.
revoke all on function public.purge_deleted_accounts() from public;

-- ────────────────────────────────────────────────── pg_cron schedule (§5) ────
-- 03:30 IST = 22:00 UTC (IST = UTC+5:30). pg_cron interprets the schedule in
-- UTC by default; the comment records the intended local time.
create extension if not exists pg_cron;

-- ponytail: schedule uses fixed UTC (22:00) for 03:30 IST — correct while the
--   launch cities are IST-only. If a non-IST region is added, switch to
--   cron.schedule_in_database with an explicit cron.timezone, or split per zone.
select cron.schedule(
  'purge_deleted_accounts',
  '0 22 * * *',
  $cron$ select public.purge_deleted_accounts(); $cron$
);

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
