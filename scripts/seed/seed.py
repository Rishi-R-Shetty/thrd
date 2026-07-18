#!/usr/bin/env python3
"""
Thrd Spaces — OSM/Overpass seed pipeline (Phase 2, task T20; decisions D6/D7).

Fetches third-place venues (cafes, parks, studios, cultural venues) for the two
launch cities from OpenStreetMap via the Overpass API, maps OSM tags to our
`space_category` enum, validates and curates ~100-200 rows per city, and loads
them idempotently into `public.spaces` keyed on `source_ref` (osm:node/<id> or
osm:way/<id>) so re-runs never duplicate.

WHY OSM AND NOT GOOGLE PLACES (D7): Google Places ToS forbids persisting place
details beyond place IDs. OSM data is ODbL-licensed for exactly this use. Every
row carries `source_ref` for idempotent re-runs; attribution ships in the app's
About screen and docs/compliance/attribution.md (ODbL share-alike).

SECRETS (D7): the DB connection comes ONLY from the SEED_DATABASE_URL env var.
Nothing is ever written to a file with credentials in it, and the script REFUSES
to run if its connection string (or a service-role JWT) is found in any
git-tracked file — a guard against someone hardcoding the hosted key.

Usage:
  # Emit idempotent SQL only (no DB, no secrets needed):
  python3 scripts/seed/seed.py --city all --emit-sql /tmp/spaces_seed.sql

  # Load directly (local stack or hosted), key from env:
  export SEED_DATABASE_URL='postgresql://…'      # never commit this
  python3 scripts/seed/seed.py --city all --load

  # Bounded smoke run (few rows, one category) for validating the pipeline:
  python3 scripts/seed/seed.py --city bengaluru --limit 20 --radius-m 3000 --load

Python 3.9+, standard library only. psql must be on PATH for --load.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ── launch cities (D6) ───────────────────────────────────────────────────────
CITIES = {
    "bengaluru": {"lat": 12.9716, "lon": 77.5946, "city_label": "Bengaluru"},
    "mumbai":    {"lat": 19.0760, "lon": 72.8777, "city_label": "Mumbai"},
}

# ── OSM tag → space_category ('cafe'|'park'|'studio'|'venue'|'other') ─────────
# Ordered: the first matching rule wins, so more specific tags precede fallbacks.
# Each rule is (osm_key, osm_value_or_None, category). value None = key present.
CATEGORY_RULES = [
    ("amenity", "cafe", "cafe"),
    ("shop", "coffee", "cafe"),
    ("leisure", "park", "park"),
    ("leisure", "garden", "park"),
    ("leisure", "fitness_centre", "studio"),
    ("amenity", "studio", "studio"),
    ("craft", None, "studio"),          # art/pottery/photo studios
    ("amenity", "arts_centre", "venue"),
    ("amenity", "theatre", "venue"),
    ("amenity", "community_centre", "venue"),
    ("amenity", "events_venue", "venue"),
    ("tourism", "gallery", "venue"),
]

# The Overpass tag filters we actually request (keeps the query bounded).
OVERPASS_SELECTORS = [
    '["amenity"="cafe"]',
    '["shop"="coffee"]',
    '["leisure"="park"]',
    '["leisure"="garden"]',
    '["leisure"="fitness_centre"]',
    '["amenity"="studio"]',
    '["craft"]',
    '["amenity"="arts_centre"]',
    '["amenity"="theatre"]',
    '["amenity"="community_centre"]',
    '["amenity"="events_venue"]',
    '["tourism"="gallery"]',
]

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",  # mirror (D7 flakiness note)
]


def categorize(tags):
    """Map an OSM element's tags to a space_category, or None to drop it."""
    for key, val, cat in CATEGORY_RULES:
        if key in tags and (val is None or tags[key] == val):
            return cat
    return None


def build_query(lat, lon, radius_m):
    """Overpass QL: nodes+ways for our selectors within radius; ways get centers."""
    parts = []
    for sel in OVERPASS_SELECTORS:
        parts.append(f'  node{sel}(around:{radius_m},{lat},{lon});')
        parts.append(f'  way{sel}(around:{radius_m},{lat},{lon});')
    body = "\n".join(parts)
    return f"[out:json][timeout:60];\n(\n{body}\n);\nout center tags;"


def fetch_overpass(query, retries=3):
    """POST the query, trying each endpoint with backoff. Returns the elements list."""
    last_err = None
    for endpoint in OVERPASS_ENDPOINTS:
        for attempt in range(retries):
            try:
                data = query.encode("utf-8")
                req = urllib.request.Request(
                    endpoint, data=data,
                    headers={"Content-Type": "text/plain",
                             "User-Agent": "ThrdSpaces-seed/1.0 (+ODbL OSM import)"})
                with urllib.request.urlopen(req, timeout=90) as resp:
                    return json.loads(resp.read().decode("utf-8")).get("elements", [])
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
                last_err = e
                wait = 2 ** attempt
                sys.stderr.write(f"  overpass {endpoint} attempt {attempt+1} failed "
                                 f"({e}); retrying in {wait}s\n")
                time.sleep(wait)
    raise RuntimeError(f"Overpass unreachable on all endpoints: {last_err}")


def element_coords(el):
    """(lat, lon) for a node, or the computed center for a way."""
    if el.get("type") == "node":
        return el.get("lat"), el.get("lon")
    center = el.get("center") or {}
    return center.get("lat"), center.get("lon")


def build_address(tags, city_label):
    """Best-effort street address from addr:* tags, falling back to the city."""
    num = tags.get("addr:housenumber", "").strip()
    street = tags.get("addr:street", "").strip()
    locality = tags.get("addr:suburb") or tags.get("addr:city") or city_label
    line = " ".join(p for p in [num, street] if p).strip()
    parts = [p for p in [line, locality] if p]
    return ", ".join(parts) if parts else city_label


def completeness_score(tags):
    """Curation heuristic — richer rows first when we have to trim to the cap."""
    score = 0
    for k in ("name", "addr:street", "addr:housenumber", "opening_hours",
              "website", "phone"):
        if tags.get(k):
            score += 1
    return score


def collect_city(key, radius_m, limit):
    """Fetch + validate + curate rows for one city. Returns a list of dicts."""
    conf = CITIES[key]
    sys.stderr.write(f"[{key}] querying Overpass within {radius_m}m of "
                     f"{conf['lat']},{conf['lon']}…\n")
    elements = fetch_overpass(build_query(conf["lat"], conf["lon"], radius_m))
    sys.stderr.write(f"[{key}] {len(elements)} raw elements\n")

    seen = set()
    rows = []
    for el in elements:
        tags = el.get("tags") or {}
        name = (tags.get("name") or "").strip()
        if not name or len(name) > 120:          # spaces.name CHECK (1..120)
            continue
        category = categorize(tags)
        if category is None:
            continue
        lat, lon = element_coords(el)
        if lat is None or lon is None:
            continue
        source_ref = f"osm:{el.get('type')}/{el.get('id')}"
        if source_ref in seen:
            continue
        seen.add(source_ref)
        rows.append({
            "name": name,
            "category": category,
            "lat": float(lat),
            "lon": float(lon),
            "address": build_address(tags, conf["city_label"]),
            "source_ref": source_ref,
            "_score": completeness_score(tags),
        })

    rows.sort(key=lambda r: r["_score"], reverse=True)
    if len(rows) > limit:
        rows = rows[:limit]
    sys.stderr.write(f"[{key}] {len(rows)} validated rows (cap {limit})\n")
    return rows


def sql_literal(s):
    """Single-quote-escape a string for SQL."""
    return "'" + s.replace("'", "''") + "'"


def rows_to_sql(rows):
    """Idempotent upsert keyed on the partial-unique source_ref index."""
    lines = [
        "-- Generated by scripts/seed/seed.py — OSM/Overpass import (ODbL).",
        "-- Idempotent on public.spaces.source_ref (partial unique index).",
        "begin;",
    ]
    for r in rows:
        loc = (f"extensions.st_setsrid(extensions.st_makepoint("
               f"{r['lon']:.7f},{r['lat']:.7f}),4326)::extensions.geography")
        lines.append(
            "insert into public.spaces (name, category, location, address, source_ref) values ("
            f"{sql_literal(r['name'])}, {sql_literal(r['category'])}::public.space_category, "
            f"{loc}, {sql_literal(r['address'])}, {sql_literal(r['source_ref'])}) "
            "on conflict (source_ref) where source_ref is not null do update set "
            "name = excluded.name, category = excluded.category, "
            "location = excluded.location, address = excluded.address;"
        )
    lines.append("commit;")
    return "\n".join(lines) + "\n"


def assert_key_not_in_repo(secret):
    """D7 guard: refuse to run if the connection secret is hardcoded in a tracked file."""
    if not secret:
        return
    # Only meaningful tokens (avoid matching on 'postgresql://' scheme alone).
    needle = secret.split("@")[-1] if "@" in secret else secret
    if len(needle) < 8:
        return
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        # Resolve the repo root: `git grep` from a subdirectory otherwise only
        # searches that subtree, silently missing a key hardcoded elsewhere.
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             cwd=here, capture_output=True, text=True)
        if top.returncode != 0:
            return
        tracked = subprocess.run(
            ["git", "grep", "-l", "-F", needle],
            cwd=top.stdout.strip(), capture_output=True, text=True)
    except FileNotFoundError:
        return
    if tracked.returncode == 0 and tracked.stdout.strip():
        sys.stderr.write("REFUSING TO RUN: the seed connection secret appears in a "
                         "git-tracked file:\n" + tracked.stdout)
        sys.stderr.write("Move it to the SEED_DATABASE_URL env var and remove it from "
                         "the repo (D7 — no service-role material in the tree).\n")
        sys.exit(2)


def load_via_psql(sql, db_url):
    """Pipe the SQL into psql. The URL is never echoed."""
    proc = subprocess.run(
        ["psql", db_url, "-v", "ON_ERROR_STOP=1", "-q", "-f", "-"],
        input=sql, text=True, capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit("psql load failed (see above).")
    sys.stderr.write("load OK\n")


def main():
    ap = argparse.ArgumentParser(description="OSM → Thrd Spaces seed pipeline")
    ap.add_argument("--city", choices=["bengaluru", "mumbai", "all"], default="all")
    ap.add_argument("--limit", type=int, default=150,
                    help="max rows per city (D6: 100-200/city)")
    ap.add_argument("--radius-m", type=int, default=8000, help="search radius per city")
    ap.add_argument("--emit-sql", metavar="PATH",
                    help="write idempotent SQL here instead of loading")
    ap.add_argument("--load", action="store_true",
                    help="load into SEED_DATABASE_URL via psql")
    args = ap.parse_args()

    if not args.emit_sql and not args.load:
        ap.error("choose --emit-sql PATH or --load")

    # Load pre-flight BEFORE any network fetch: fail fast if the connection is
    # missing or a secret is hardcoded in the tree (D7), so we neither hit
    # Overpass nor do work we'd only discard.
    db_url = None
    if args.load:
        db_url = os.environ.get("SEED_DATABASE_URL")
        if not db_url:
            raise SystemExit("--load needs SEED_DATABASE_URL in the environment (never a file).")
        assert_key_not_in_repo(db_url)
        assert_key_not_in_repo(os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""))

    keys = ["bengaluru", "mumbai"] if args.city == "all" else [args.city]
    rows = []
    for k in keys:
        rows.extend(collect_city(k, args.radius_m, args.limit))
    if not rows:
        raise SystemExit("no rows collected — widen tags/radius, do not switch to Google (D7).")

    sql = rows_to_sql(rows)

    if args.emit_sql:
        with open(args.emit_sql, "w") as f:
            f.write(sql)
        sys.stderr.write(f"wrote {len(rows)} rows of SQL → {args.emit_sql}\n")

    if args.load:
        load_via_psql(sql, db_url)
        sys.stderr.write(f"loaded {len(rows)} spaces (idempotent on source_ref)\n")


if __name__ == "__main__":
    main()
