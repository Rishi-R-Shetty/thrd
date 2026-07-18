# Data Attribution & Licensing

## OpenStreetMap (venue seed data) — ODbL 1.0

Thrd Spaces seeds its `spaces` table (cafes, parks, studios, cultural venues) from
**OpenStreetMap** via the Overpass API (`scripts/seed/seed.py`, task T20; decision
D7). OpenStreetMap data is licensed under the **Open Database License (ODbL) 1.0**.

### Obligations we meet

1. **Attribution (required).** The credit **"© OpenStreetMap contributors"** is
   displayed in-app on **Settings → About**, and on the public website/marketing
   pages that show map or venue data. The credit links to
   <https://www.openstreetmap.org/copyright>.

2. **Share-Alike (Produced Work vs Derivative Database).** Our `spaces` table is a
   **Derivative Database** of OSM (we import and adapt OSM records). The app screens
   that render this data are a **Produced Work** — for a Produced Work, ODbL requires
   attribution only (above), not release of the database. If we ever **publicly
   distribute the derivative database itself** (e.g. a data export/API of our venue
   table), the adapted OSM-derived portion must be offered under ODbL. We do not
   distribute the database today; this is flagged so a future "venue export" feature
   revisits it before shipping.

3. **Provenance for traceability.** Every seeded row carries `source_ref`
   (`osm:node/<id>` or `osm:way/<id>`), so the OSM origin of each record is
   auditable and re-imports are idempotent.

### What we do NOT do (D7)

- **Google Places is prohibited** as a source for any persisted data — its ToS
  forbids storing place details beyond place IDs. If OSM coverage for a category is
  thin, the fix is widening the OSM tag set (`scripts/seed/seed.py`
  `OVERPASS_SELECTORS` / `CATEGORY_RULES`), never switching to Google.

## Overpass API usage

We query public Overpass endpoints read-only, with a descriptive `User-Agent`, a
bounded per-city radius, retry/backoff, and a mirror fallback. Seed runs are
occasional (initial launch + refreshes), well within fair-use.
