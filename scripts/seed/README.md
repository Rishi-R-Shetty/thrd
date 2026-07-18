# Seed pipeline — OSM → Thrd Spaces (`spaces`)

Populates `public.spaces` for the two launch cities (Bengaluru + Mumbai) from
OpenStreetMap via Overpass. Task T20; decisions **D6** (two cities, 100–200/city)
and **D7** (OSM only — Google Places prohibited for stored data).

## Requirements
- Python 3.9+ (standard library only — no pip installs).
- `psql` on PATH (for `--load`).
- Network access to the Overpass API.

## Secrets (D7) — read this first
The DB connection is taken **only** from the `SEED_DATABASE_URL` environment
variable. It is never read from or written to a file, and never printed. The
script **refuses to run** if that connection string (or `SUPABASE_SERVICE_ROLE_KEY`)
is found in any git-tracked file — a guard against hardcoding the hosted key.

**Never commit a hosted service-role key or a hosted `postgresql://…` URL.**

## Usage

```bash
# 1) Emit idempotent SQL only (no DB, no secrets):
python3 scripts/seed/seed.py --city all --emit-sql /tmp/spaces_seed.sql

# 2) Load into the local stack (demo credentials are a documented non-secret):
export SEED_DATABASE_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2- | tr -d '\"')"
python3 scripts/seed/seed.py --city all --load

# 3) Load into the HOSTED project (paste the hosted DB URL into the env, never a file):
export SEED_DATABASE_URL='postgresql://postgres:<pw>@db.<ref>.supabase.co:5432/postgres'
python3 scripts/seed/seed.py --city all --load
unset SEED_DATABASE_URL
```

Flags: `--city bengaluru|mumbai|all`, `--limit N` (rows/city, default 150),
`--radius-m` (default 8000), `--emit-sql PATH`, `--load`.

## Idempotency
Rows upsert on `spaces.source_ref` (`osm:node/<id>` / `osm:way/<id>`), which has a
partial unique index. Re-running updates in place — **zero duplicates** (verified
against the local stack: 25 → 25 on a repeat run).

## Categories
OSM tags map to `space_category` (`cafe|park|studio|venue|other`) via
`CATEGORY_RULES` in `seed.py`. Widen `OVERPASS_SELECTORS` / `CATEGORY_RULES` if a
category is thin in a city — **do not** switch to Google Places (D7).

## Attribution (ODbL)
Seeded data requires "© OpenStreetMap contributors" in Settings → About and on the
website. See `docs/compliance/attribution.md`.

## Status
Pipeline verified end-to-end against the local stack (fetch → validate → categorize
→ idempotent load). **Hosted population is pending the hosted deploy** (link + `db
push` + service-role key available locally) — a standing user action. Run form (3)
above once the hosted project is reachable.
