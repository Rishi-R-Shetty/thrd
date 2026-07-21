-- ============================================================================
-- Thrd Spaces — 0006_erasure_integrity.sql (Phase 3, task T22a; decision D12)
-- Resolves the D11 purge-vs-RESTRICT landmine and closes Phase-2 audit findings
-- F3 (incomplete erasure) and F10 (silent skips). The coordinated app-layer half
-- (grace-start cancel RPC + delete_account rework + rsvp_event_tx grace-guard +
-- EventDetail null-host fallback + F8 batched-commit procedure) is T22b — this
-- migration is self-contained SQL and needs no Edge/client change to be correct.
--
-- Changes:
--   1. events.host_id / communities.creator_id → NULLABLE + ON DELETE SET NULL.
--      A purged user's residual owned rows null out instead of blocking the
--      cascade with a RESTRICT throw (D12 §1). No tombstone user.
--   2. notification_outbox table (schema only; writers land in T22b/T32).
--   3. communities.archived_at + communities_select_public excludes archived.
--   4. rsvp_event_tx: the event-openness gate now applies to the `rsvp` action
--      only, so an attendee can always cancel their own ticket on a
--      host-cancelled / completed event (D12 §4 — was audit's cancel-lock bug).
--   5. purge_deleted_accounts rewrite: DPDP segmentation (delete sole-owner
--      drafts + sole-member communities; SET NULL-retain counterparty rows),
--      COMPLETE uuid re-key (audit actor + metadata subject_id/target, and
--      erase reports where the purged user is the subject), and a durable
--      `purge_skipped` audit row on any per-user failure (F3 + F10).
--
-- Deferred to T22b (logged in the plan): grace-start cancellation RPC,
-- delete_account calling it + dry-run preflight, rsvp_event_tx grace-guard
-- (needs a new Edge result mapping), F8 batched-commit (procedure form —
-- a scale-only lock optimization; correctness here is unaffected).
-- ============================================================================

-- ─────────────────────────── 1. FK flips: RESTRICT → SET NULL (D12 §1) ───────
-- events.host_id and communities.creator_id were NOT NULL + ON DELETE RESTRICT
-- (0001), which is exactly what made purge fail on a user who hosts an event or
-- created a community. Make them nullable and SET NULL so the auth.users delete
-- cascade clears them instead of throwing. Nothing depends on non-null here:
-- tickets_select_own_or_host simply never matches a null host, and residual rows
-- after purge are retained counterparty data (completed events, multi-member
-- communities). EventDetail's null-host fallback ships in T22b.

alter table public.events
  drop constraint events_host_id_fkey,
  alter column host_id drop not null,
  add constraint events_host_id_fkey
    foreign key (host_id) references public.users(id) on delete set null;

alter table public.communities
  drop constraint communities_creator_id_fkey,
  alter column creator_id drop not null,
  add constraint communities_creator_id_fkey
    foreign key (creator_id) references public.users(id) on delete set null;

-- ─────────────────────────── 2. notification_outbox (schema only) ───────────
-- The durable queue for cancel-and-notify (T22b grace flow) and reminders/
-- announcements (T32 push). Default-deny RLS, zero client policies: only the
-- service_role writer and the postgres-owned sender ever touch it. Payload is
-- sanitized at write time (threat-model rule 10 — no message bodies).
create table public.notification_outbox (
  id           uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.users(id) on delete cascade,
  category     text not null check (category in
                 ('event_cancelled','event_reminder','rsvp_confirmation',
                  'community_announcement')),
  payload      jsonb not null default '{}'::jsonb,
  collapse_id  text,                    -- APNs collapse key (dedupe)
  scheduled_for timestamptz not null default now(),
  sent_at      timestamptz,
  status       text not null default 'pending'
                 check (status in ('pending','sent','failed','skipped')),
  created_at   timestamptz not null default now()
);
alter table public.notification_outbox enable row level security;  -- default-deny, no policies
revoke all on public.notification_outbox from anon, authenticated;

-- Cheap scan for the sender/reminder cron: due, still pending.
create index notification_outbox_due_idx
  on public.notification_outbox (scheduled_for)
  where status = 'pending';

-- ─────────────────────────── 3. communities archive column (D12 §5) ─────────
alter table public.communities
  add column archived_at timestamptz;    -- set at purge for sole-member communities (T22b)

-- Archived communities disappear from the public listing. (Recreate the policy
-- with the extra predicate — CREATE OR REPLACE POLICY is not available.)
drop policy communities_select_public on public.communities;
create policy communities_select_public on public.communities for select
  to authenticated using (visibility = 'public' and archived_at is null);

-- ─────────────────────────── 4. rsvp_event_tx cancel-on-cancelled fix ────────
-- Only change vs 0004: the openness gate (published + future + free) now guards
-- the `rsvp` action alone. A `cancel` proceeds regardless of event status, so an
-- attendee can always walk back a ticket on a host-cancelled or completed event
-- (D12 §4). not_found for unknown/draft still applies to both actions (no draft
-- oracle). The Edge Function's result mapping is unchanged (still 'ok'/'cancelled').
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
  select status, starts_at, price, capacity, rsvp_count
    into v_status, v_starts_at, v_price, v_capacity, v_count
    from public.events
   where id = p_event_id
     for update;

  -- Unknown id and drafts are indistinguishable (no draft-existence oracle).
  if not found or v_status = 'draft' then
    return jsonb_build_object('result', 'not_found');
  end if;

  if p_action = 'rsvp' then
    -- Openness applies to RSVP only. cancelled/completed/past/paid → not open.
    if v_status <> 'published'
       or v_starts_at <= now()
       or v_price > 0 then
      return jsonb_build_object('result', 'event_not_open');
    end if;

    -- Tier-0 cap (threat-model Layer 3), read server-side.
    select verification_status into v_vs
      from public.users where id = p_user_id;
    if v_vs = 'none' and (v_capacity is null or v_capacity > 20) then
      return jsonb_build_object('result', 'verification_required');
    end if;
  end if;

  -- Own ticket (if any), locked. unique(event_id,user_id) → at most one.
  select id, status into v_ticket_id, v_ticket_st
    from public.tickets
   where event_id = p_event_id and user_id = p_user_id
     for update;

  if p_action = 'rsvp' then
    if v_ticket_id is not null
       and v_ticket_st in ('going', 'waitlist', 'checked_in') then
      return jsonb_build_object(
        'result', 'ok', 'status', v_ticket_st, 'rsvp_count', v_count);
    end if;

    if v_capacity is null or v_count < v_capacity then
      v_new_status := 'going';
    else
      v_new_status := 'waitlist';
    end if;

    if v_ticket_id is not null then
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

  else  -- p_action = 'cancel' — always allowed to reach here (D12 §4)
    if v_ticket_id is null or v_ticket_st = 'cancelled' then
      return jsonb_build_object(
        'result', 'ok', 'status', 'cancelled', 'rsvp_count', v_count);
    end if;

    update public.tickets set status = 'cancelled' where id = v_ticket_id;

    -- Only a `going` seat on a still-counting event frees capacity. If the event
    -- was already cancelled/completed its rsvp_count is historical, but the
    -- promote/decrement logic remains correct (promote keeps net count; else
    -- decrement) so a live event reconciles exactly as before.
    if v_ticket_st = 'going' then
      select id into v_promoted
        from public.tickets
       where event_id = p_event_id and status = 'waitlist'
       order by purchased_at asc
       limit 1
         for update skip locked;

      if v_promoted is not null then
        update public.tickets set status = 'going' where id = v_promoted;
      else
        update public.events set rsvp_count = greatest(rsvp_count - 1, 0)
         where id = p_event_id
        returning rsvp_count into v_count;
      end if;
    end if;

    return jsonb_build_object(
      'result', 'ok', 'status', 'cancelled', 'rsvp_count', v_count);
  end if;
end;
$$;

revoke all on function public.rsvp_event_tx(uuid, uuid, text) from public;
grant execute on function public.rsvp_event_tx(uuid, uuid, text) to service_role;

-- ─────────────────────────── 5. purge rewrite (F3 + F10 + D12 §5) ────────────
-- Same ownership/kill-switch/pepper posture as 0004. New: DPDP segmentation of
-- the purged user's owned content, a COMPLETE uuid re-key (actor column AND
-- audit metadata subject_id/target, plus erasing reports where the user is the
-- subject — reports has no metadata jsonb to re-key into), and a durable
-- `purge_skipped` row so a failed erasure is queryable, not just a NOTICE.
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
  v_hash    text;
  v_purged  integer := 0;
  v_skipped integer := 0;
  v_err     text;
begin
  select enabled into v_enabled from public.feature_flags
   where key = 'fn:purge_deleted_accounts';
  if v_enabled is not null and v_enabled = false then
    raise notice 'purge_deleted_accounts: disabled by kill switch';
    return 0;
  end if;

  select decrypted_secret into v_pepper from vault.decrypted_secrets
   where name = 'purge_pepper';
  if v_pepper is null then
    raise exception 'purge_deleted_accounts: missing purge_pepper secret';
  end if;

  for v_uid in
    select id from public.users
     where deletion_requested_at < now() - interval '30 days'
  loop
    v_err  := null;
    v_hash := encode(extensions.digest(v_uid::text || v_pepper, 'sha256'), 'hex');
    begin
      -- (1) Re-key EVERY appearance of the uuid in audit_log, not just the
      -- actor column (F3): the actor rows, plus metadata subject_id/target that
      -- submit_report / manage_block wrote about this user.
      update public.audit_log
         set user_id = null,
             metadata = metadata || jsonb_build_object('purged_user', v_hash)
       where user_id = v_uid;
      update public.audit_log
         set metadata = jsonb_set(metadata, '{subject_id}', to_jsonb(v_hash))
       where metadata->>'subject_id' = v_uid::text;
      update public.audit_log
         set metadata = jsonb_set(metadata, '{target}', to_jsonb(v_hash))
       where metadata->>'target' = v_uid::text;

      -- (1b) Reports where the purged user is the SUBJECT survive the cascade
      -- (subject_id is polymorphic, no FK) and hold the raw uuid with no
      -- metadata column to re-key into → erase them (F3). Reports BY the user
      -- (reporter_id) cascade-delete via the auth.users delete below.
      delete from public.reports
       where subject_type = 'user' and subject_id = v_uid;

      -- (2) DPDP segmentation (D12 §5): delete the purged user's sole-owner
      -- content that has no counterparty interest — draft events (only ever
      -- visible to them) and future-cancelled events with no other attendee,
      -- and communities where they are the only member. Retained rows
      -- (completed events, cancelled-with-attendees, multi-member communities)
      -- fall through to the SET NULL cascade as defensible counterparty data.
      delete from public.events e
       where e.host_id = v_uid
         and (e.status = 'draft'
              or (e.status = 'cancelled' and e.starts_at > now()
                  and not exists (
                    select 1 from public.tickets t
                     where t.event_id = e.id
                       and t.user_id <> v_uid
                       and t.status <> 'cancelled')));
      delete from public.communities c
       where c.creator_id = v_uid
         and not exists (
           select 1 from public.community_memberships m
            where m.community_id = c.id and m.user_id <> v_uid);

      -- (3) Hard-delete PII. auth.users → public.users cascade nulls residual
      -- host_id/creator_id (now SET NULL) and cascade-deletes tickets,
      -- memberships, blocks (both directions), reports.reporter. RESTRICT no
      -- longer exists, so this never throws on a host/creator.
      delete from auth.users where id = v_uid;

      v_purged := v_purged + 1;
    exception when others then
      v_err := sqlerrm;   -- captured; recorded durably below in a clean state
    end;

    if v_err is not null then
      -- Durable, queryable evidence of a skipped erasure (F10) — no more
      -- silent NOTICE-only skips. Keyed by the same salted hash, never the uuid.
      insert into public.audit_log (user_id, action, metadata)
      values (null, 'purge_skipped',
              jsonb_build_object('purged_user', v_hash, 'reason', v_err));
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  insert into public.audit_log (user_id, action, metadata)
  values (null, 'purge_run',
          jsonb_build_object('purged', v_purged, 'skipped', v_skipped));

  return v_purged;
end;
$$;

alter function public.purge_deleted_accounts() owner to postgres;
revoke all on function public.purge_deleted_accounts() from public;

-- ─────────────────────────── self-check: RLS still on every table ───────────
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
