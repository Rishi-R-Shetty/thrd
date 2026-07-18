# Hosted Deploy Runbook — Supabase (Phase 1+2 backend)

Project ref: **`emfzwfnfsqhhybnzfhsy`** · Migrations: 0001–0005 · Edge Functions: `delete_account`, `submit_report`, `manage_block`, `rsvp_event` · DB cron function: `purge_deleted_accounts` (in 0004).

Run from the repo root. Steps marked **[Dashboard]** are manual (can't be scripted); **[CLI]** are commands. **Do the dashboard prereqs BEFORE `db push`** — 0004 fails without pg_cron + Vault.

---

## 0. Prerequisites [Dashboard] — before any push

1. **Enable `pg_cron`** — Database → Extensions → search `pg_cron` → enable. (0004 calls `cron.schedule` for the nightly purge; without it the migration errors.)
2. **Confirm `supabase_vault` is enabled** — Database → Extensions → `supabase_vault` (default-on for new projects). 0004 reads/writes the `purge_pepper` secret via `vault.*`.
3. **`postgis`** — 0001 runs `create extension if not exists postgis with schema extensions`; available on hosted, no manual step, but confirm the `extensions` schema exists (default).
4. **Grab the project JWT secret** — Settings → API → **JWT Secret**. You'll set this as `THRD_JWT_SECRET` so in-function verification matches gateway-issued tokens. (They MUST be identical.)
5. **Enable ≥1 auth provider** — Authentication → Providers → enable **Sign in with Apple** and/or **Phone** (OTP needs an SMS provider configured). Required for a real end-to-end sign-in.

## 1. Link the project [CLI]

```bash
supabase link --project-ref emfzwfnfsqhhybnzfhsy
# prompts for the database password (Settings → Database → Password)
```

## 2. (Recommended) Pre-seed the purge pepper [Dashboard → SQL editor]

So the audit re-key hash is stable across restores (0004 otherwise seeds a random one on first apply):

```sql
select vault.create_secret(
  encode(gen_random_bytes(32), 'hex'),  -- 64-hex random pepper
  'purge_pepper',
  'One-way re-key pepper for purged users audit rows (D12).'
);
```
Run this BEFORE `db push`; the migration then skips its random fallback.

## 3. Push migrations [CLI]

```bash
supabase db push          # applies 0001 → 0005 in order
```
Expect: schema + RLS + views + RPCs + `rsvp_event_tx` + `purge_deleted_accounts` + the pg_cron schedule + 0005 block-invisibility. If it fails on 0004, re-check step 0.1/0.2.

## 4. Set the function secret [CLI]

```bash
supabase secrets set THRD_JWT_SECRET='<paste the project JWT secret from step 0.4>'
```
(`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected into Edge Functions — do NOT set those, and never put the service-role key in the repo.)

## 5. Deploy the Edge Functions [CLI]

```bash
supabase functions deploy delete_account
supabase functions deploy submit_report
supabase functions deploy manage_block
supabase functions deploy rsvp_event
```
Platform `verify_jwt` stays default-on (Artifact B posture — belt-and-suspenders; the in-function `role=authenticated` check is the load-bearing one).

## 6. Seed the two cities [CLI]

Use the direct connection string (Settings → Database → Connection string → URI, includes the password). Keep it in the env only, never a file (the seed guard enforces this):

```bash
export SEED_DATABASE_URL='postgresql://postgres:<db-password>@db.emfzwfnfsqhhybnzfhsy.supabase.co:5432/postgres'
python3 scripts/seed/seed.py --city all --load     # ~100–200 spaces per city
unset SEED_DATABASE_URL
```
Re-runnable (idempotent on `source_ref`). If Overpass is flaky, re-run — it upserts.

## 7. Verify [CLI / Dashboard]

```bash
# counts per city landed:
psql "$SEED_DATABASE_URL" -tAc "select count(*) from public.spaces where source_ref like 'osm:%';"
# RLS on every table (0 rows = good):
psql "$SEED_DATABASE_URL" -tAc "select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;"
# cron job installed:
psql "$SEED_DATABASE_URL" -tAc "select jobname, schedule from cron.job;"
```
- **[Dashboard]** Edge Functions → confirm all four are deployed and healthy.
- Optionally run the hostile suite against a *throwaway* stack, not production.

## 8. Point the client at hosted + full T21 demo

1. Confirm `thrdspaces/thrdspaces/Configuration.plist` holds the **hosted** project URL + **anon** key (only the anon key — never the service-role key). Update if it still points at local.
2. For the age gate to return real results, ensure the `com.apple.developer.declared-age-range` entitlement + provisioning are in place (else it falls back to attestation — fine for the demo).
3. Run the app against hosted: **find a nearby seeded event → RSVP → confirm the ticket row exists** (Discover → Event Detail → RSVP → "You're going"). That closes the PRD Phase 2 exit criterion on-device — the one open T21 item.

---

## Notes
- Nothing here is destructive to local. `db push` targets the linked hosted project.
- If a migration half-applies, fix the prereq and re-run `supabase db push` (it resumes at the first unapplied migration).
- Keep the DB password and service-role key out of the repo at all times; the seed guard will refuse to run if it finds either in a tracked file.
