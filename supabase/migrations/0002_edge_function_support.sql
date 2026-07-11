-- ============================================================================
-- Thrd Spaces — 0002_edge_function_support.sql (Phase 1, task T7b)
-- Supporting schema for the privileged Edge Functions (Artifact B):
--   delete_account · submit_report · manage_block.
--
-- Adds two service-only tables (rate_limit_counters, feature_flags), one
-- atomic rate-limit RPC, and the minimal service_role privileges the functions
-- need. Both new tables: RLS-enabled default-deny, ZERO client policies, ZERO
-- client grants (hostile-test asserted in tests/rls_hostile_user_tests.sql).
--
-- REVIEW NOTE (orchestrator, per A2 review gate): 0001 designates service_role
-- as the direct write path for reports/blocks/users/audit_log ("service_role,
-- BYPASSRLS, the only write path"), but under the new "not-auto-exposed" Data
-- API default, service_role was never GRANTed DML on those tables — it holds
-- BYPASSRLS yet lacks table privileges, so every Edge Function write fails with
-- 42501. This migration closes that gap with the *minimal, column-scoped*
-- grants each function actually uses. audit_log stays insert-only for every
-- role (0001's update/delete revoke is preserved). No RLS policy is added or
-- changed; no client (anon/authenticated) grant is added anywhere.
-- ============================================================================

-- ─────────────────────────────────────────────────── rate_limit_counters ────
-- Windowed per-key counters. Keys are function-scoped and carry the caller id
-- or client IP (e.g. "submit_report:user:<uuid>:h"). Written only by the
-- consume_rate_limit RPC (security-definer), never touched directly by clients.
create table public.rate_limit_counters (
  bucket_key   text        not null,
  window_start timestamptz not null,   -- date_trunc('hour'|'day', now()), set server-side
  count        integer     not null default 0,
  primary key (bucket_key, window_start)
);

-- ponytail: no TTL/sweep on expired windows in Phase 1 — rows accumulate slowly
--   (one per key per window). Add a nightly pg_cron delete of window_start <
--   now() - interval '2 days' if the table grows past a few hundred k rows.

alter table public.rate_limit_counters enable row level security;
-- No policies, and revoke the Data API roles explicitly (guard, independent of
-- the not-auto-exposed default). Only the security-definer RPC writes here.
revoke all on public.rate_limit_counters from anon, authenticated;

-- ────────────────────────────────────────────────────────── feature_flags ───
-- Kill switches, flipped from the dashboard without a deploy. Read at the entry
-- of every Edge Function; a row with enabled=false returns 503 unavailable.
create table public.feature_flags (
  key        text primary key,
  enabled    boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.feature_flags enable row level security;
-- No policies; no client grants. service_role reads it (grant below).
revoke all on public.feature_flags from anon, authenticated;

grant select on public.feature_flags to service_role;

-- Seed the Phase-1 function flags, all enabled.
insert into public.feature_flags (key, enabled) values
  ('fn:delete_account', true),
  ('fn:submit_report',  true),
  ('fn:manage_block',   true);

-- ─────────────────────────────────────────── consume_rate_limit RPC ─────────
-- Atomic multi-bucket increment-and-check. Takes a jsonb array of
--   { "key": text, "granularity": "hour"|"day", "limit": int }
-- increments each bucket in the current window, and returns TRUE only if every
-- bucket is still within its limit. SECURITY DEFINER (owner: postgres) so it
-- writes rate_limit_counters without granting the table to any caller role.
-- Every value is a bound parameter — no dynamic SQL string is built.
create function public.consume_rate_limit(p_checks jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  chk       jsonb;
  v_key     text;
  v_gran    text;
  v_limit   integer;
  v_window  timestamptz;
  v_count   integer;
  v_allowed boolean := true;
begin
  for chk in select value from jsonb_array_elements(p_checks)
  loop
    v_key   := chk->>'key';
    v_gran  := chk->>'granularity';
    v_limit := (chk->>'limit')::integer;

    -- Only two granularities are ever passed; anything else is a bug, not input.
    if v_gran not in ('hour', 'day') then
      raise exception 'invalid granularity';
    end if;
    v_window := date_trunc(v_gran, now());

    insert into public.rate_limit_counters (bucket_key, window_start, count)
    values (v_key, v_window, 1)
    on conflict (bucket_key, window_start)
    do update set count = public.rate_limit_counters.count + 1
    returning count into v_count;

    if v_count > v_limit then
      v_allowed := false;   -- keep counting the remaining buckets; deny overall
    end if;
  end loop;

  return v_allowed;
end;
$$;

-- Clients must never call the limiter directly.
revoke all on function public.consume_rate_limit(jsonb) from public;
grant execute on function public.consume_rate_limit(jsonb) to service_role;

-- ──────────────────────────── minimal service_role grants (see REVIEW NOTE) ──
-- delete_account: read + flip only the grace marker on the caller's own row.
grant select (id, deletion_requested_at) on public.users to service_role;
grant update (deletion_requested_at)     on public.users to service_role;

-- submit_report: validate subject existence (id only), dedupe + insert reports.
grant select (id) on public.events      to service_role;
grant select (id) on public.communities to service_role;
grant select              on public.reports to service_role;  -- dedupe scan (moderation data)
grant insert (reporter_id, subject_type, subject_id, reason, detail)
                          on public.reports to service_role;

-- manage_block: target-existence check (id only) + upsert/delete own blocks.
-- SELECT (key columns) is required by PostgREST's upsert conflict path and by
-- the DELETE ... WHERE on the unblock path (WHERE references these columns).
grant select (blocker_id, blocked_id) on public.blocks to service_role;
grant insert (blocker_id, blocked_id) on public.blocks to service_role;
grant delete                          on public.blocks to service_role;

-- audit envelope: one insert-only row per invocation. UPDATE/DELETE stay revoked
-- from service_role (0001) — audit_log remains append-only.
grant insert (user_id, action, metadata) on public.audit_log to service_role;

-- ─────────────────────────────── self-check: new tables have RLS enabled ─────
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
