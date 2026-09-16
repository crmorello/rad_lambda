# Raster tile API — client integration

XYZ raster tiles rendered on demand from the RAD frames. Plain PNG over HTTPS,
no SDK, no auth today.

**Base URL (temporary):**
`https://bjbvpovuzmss2unukwaxwb7vfa0qtsrb.lambda-url.us-east-1.on.aws`

This is the Lambda Function URL. It moves to `<cdn-domain>/tiles/*` once
CloudFront is wired, so **keep the base configurable** — the paths below don't
change.

## Endpoints

```
GET /tiles/v1/{product}/{stamp}/{z}/{x}/{y}.png
GET /tiles/v1/{product}/latest/{z}/{x}/{y}.png     -> 302 to a stamped URL
GET /tiles/v1/{product}/manifest.json
GET /tiles/v1/{product}/timerange                  -> {"timestamps":[ISO8601,…]}
```

- `product` — `rads` (radar reflectivity), or one of the 13 obs products:
  `obs/temperature` `obs/dewpoint` `obs/rh` `obs/pressure` `obs/wind_average`
  `obs/wind_gust` `obs/wind_dir` `obs/solar_radiation` `obs/precip_rate`
  `obs/cloud_cover` `obs/tempest_pres_obs` `obs/precip_type`
  `obs/conditions_code`
- `stamp` — `YYYYMMDD-HHMMSS`, e.g. `20260915-164000`
- `z` — **0–14**. z15+ returns 404.
- Query: `size=256|512` (default 256), `tms=1` (flip y, default is XYZ),
  `palette=0|1`

Cadence: radar every 10 min, obs every 5 min.

## Responses

| | |
|---|---|
| Tile with data | `200` `image/png`, `Cache-Control: public, max-age=31536000, immutable` |
| **Tile outside coverage** | **`200`** with a ~333-byte fully transparent PNG — *not* an error |
| Unknown product, or stamp not in the manifest | `404` |
| `manifest.json` / `timerange` | `200` `application/json`, `max-age=15` |

`Access-Control-Allow-Origin: *` on every response, so browser fetches and
canvas reads both work.

## MapLibre

Default scheme is XYZ, which matches — don't set `tms`.

```js
const BASE  = '<base-url>';
const stamp = '20260915-164000';

map.addSource('radar', {
  type: 'raster',
  tiles: [`${BASE}/tiles/v1/rads/${stamp}/{z}/{x}/{y}.png`],
  tileSize: 256,
  minzoom: 0,
  maxzoom: 14,            // overzoom past 14 rather than request z15 (404s)
  attribution: 'NOAA MRMS'
});
map.addLayer({
  id: 'radar', type: 'raster', source: 'radar',
  paint: { 'raster-opacity': 0.85 }
});

// Stepping through time — swap the URL, don't recreate the source:
map.getSource('radar').setTiles([
  `${BASE}/tiles/v1/rads/${nextStamp}/{z}/{x}/{y}.png`
]);
```

For 512px tiles use `size=512` **and** `tileSize: 512`.

## Picking a stamp

`timerange` gives ISO8601 but the URL wants `YYYYMMDD-HHMMSS`. Easiest is to
read `manifest.json` instead — `frames[].id` is already in URL form:

```js
const m = await (await fetch(`${BASE}/tiles/v1/rads/manifest.json`)).json();
// radar ids carry a region prefix (alaska_, carib_, guam_, hawaii_);
// CONUS is unprefixed. obs ids never have one.
const stamps = [...new Set(m.frames.map(f => f.id.split('_').pop()))].sort();
```

From `timerange` instead: `iso.replace(/[-:]/g,'').replace('T','-').replace('Z','')`.

## Four things that will bite you

**1. Don't use `latest` for `rads` yet.** It resolves to the newest stamp across
*all* regions, and CONUS lags the smaller regions by a slice — so `latest` can
point at a stamp that has Alaska/Hawaii/Carib/Guam but **no CONUS**, giving a
blank tile over the continental US. Seen live: `latest` → `20260915-165000`
(empty over CONUS) while the newest CONUS frame was `20260915-164000`. Until
it's fixed, pick the newest stamp whose manifest `id` has **no** region prefix.
Obs products are unaffected — use `latest` freely there.

**2. `timerange` returns duplicates** for radar — one entry per region, so ~5×.
Dedupe before building a timeline (89 frames → 18 unique stamps today).

**3. A transparent tile is a 200, not a 404.** Normal outside the radar/obs
coverage area. Don't render an error state or retry.

**4. Frames expire.** Radar objects live 7 days but the manifest only lists the
last ~3 hours; obs lists ~12 hours. A stamp outside that window 404s even though
the data is still in the bucket. Always source stamps from `manifest.json` or
`timerange`, never construct them by arithmetic.

## Quick check

```bash
BASE=https://bjbvpovuzmss2unukwaxwb7vfa0qtsrb.lambda-url.us-east-1.on.aws
curl -s "$BASE/tiles/v1/rads/manifest.json" | head -c 200
curl -so tile.png "$BASE/tiles/v1/rads/20260915-164000/5/7/12.png" && open tile.png
```
