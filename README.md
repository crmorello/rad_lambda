# rad_lambda

S3-triggered lambda: MRMS precip grib2(.gz) in, RAD file out.

**Implementation: Zig (`zig/`), sharing radcore with raydare** (§14 one
language, all layers): the RAD v2 encoder lives in
`radcore/src/core.zig` (its own repo, github.com/crmorello/radcore) next to the decoder the client renders from —
one implementation of the format, parity-pinned. (The original Crystal build
was removed once the Zig output was verified byte-identical to it, golden-tested
per region; see git history before Sep 2026 if the reference is ever needed.)

Pipeline (all in-process, no temp files): open via GDAL VSI
(`/vsigzip/`, `/vsis3/`) → `GDALWarp` to EPSG:3857 at a fixed pixel density
(1222.8 m/px, prod CONUS) into a `MEM` dataset → band 1 as bytes →
radcore `writeRadV2` ("RAD2" skip-literal) → optional gzip-at-rest → written
via VSI (local path or `/vsis3/bucket/prefix`).

## Modes

- **Lambda**: when `AWS_LAMBDA_RUNTIME_API` is set (containers on AWS set it),
  runs the custom-runtime loop. Accepts SQS-wrapped SNS S3 notifications (the
  production chain: NOAA SNS -> our SQS -> event-source mapping), direct
  SNS->Lambda, or raw S3 events. Each record is routed by key extension
  (`handler.kindForKey`): grib2 to the radar path below, `.parquet` to the obs
  ingest. A key that matches neither, or whose name carries no timestamp, is
  counted in `skipped` rather than failing the batch into the DLQ.
  Per radar record: skips stamps off the 10-minute
  grid (MRMS publishes every 2 min), derives the region id prefix from the
  key's first segment (CONUS unprefixed, `ALASKA/` -> `alaska_`, ...), writes
  the RAD, then rebuilds `manifest.json` from a listing of the output dir
  (list-based on purpose — read-modify-write loses frames under concurrent
  region invocations).
  Config: `RAD_OUTPUT` (required, e.g. `/vsis3/my-bucket/rads` — ONE dir for
  all regions), `RAD_RESOLUTION` (optional, default 1222.8),
  `RAD_URL_PREFIX` (optional manifest URL prefix; defaults to the RAD_OUTPUT
  path after the bucket, e.g. `/rads`), `RAD_GZIP=0` to opt out of gzip
  bodies + Content-Encoding metadata, `RAD_UNSIGNED_BUCKETS=noaa-mrms-pds`
  (comma list) to read public input buckets anonymously — signed reads of
  public buckets can be denied by org SCPs/role gaps; writes stay signed —
  and `RAD_MANIFEST_HOURS` (default 3, 0 = unwindowed): the manifest lists
  only frames stamped within the window; older RADs stay in the bucket,
  fetchable by URL, until lifecycle expiry.
- **Obs** (same binary, its OWN lambda function): a `.parquet` key runs the H3
  observation ingest — 13 products under `{RAD_OUTPUT}/obs/{variable}/` plus a
  wind `.flw` sidecar and a manifest per variable. Point that function's
  `RAD_OUTPUT` at the **bucket root** (`/vsis3/my-bucket`), so obs lands at
  `/obs/{variable}/` as a sibling of `/rads/` and the serving path matches the
  manifest URLs obs writes. No 10-minute grid gate (issuances are off the
  lattice) and no region prefix (H3 is global). Extra config:
  `RAD_OBS_SMOOTH` (kernel scale in cell half-widths, default 1.0; 0 disables
  and reproduces the unsmoothed plateaus byte-for-byte), and
  `RAD_MANIFEST_HOURS=12` in production — at the 5-minute issuance cadence that
  is 144 frames per variable manifest (radar keeps the 3 h default). Whatever
  the obs lifecycle TTL ends up being, it must exceed this window or the
  manifests will list frames S3 has already expired. Separate functions keep
  the two products' memory, timeout, concurrency and DLQ independent.
- **`RAD_KEY_PREFIXES`** (optional, comma-separated) restricts which keys a
  function will act on; anything outside is counted in `skipped`. Set it when
  the TRIGGER is broader than the product's prefix — the obs producer invokes
  on every write to its bucket, so that function sets `gcc/output/`. Without
  it, routing is by extension alone and a stray `.parquet` elsewhere in that
  bucket would be ingested as an obs issuance (verified: it publishes 13 bogus
  products). Radar leaves it unset; its SNS filter policy already scopes the
  trigger.
- **CLI**: `rad_lambda <grib(.gz) | dir> [out_dir]`, or
  `rad_lambda --obs <file.parquet> [out_dir]`, for local testing (plain files,
  no gzip, unwindowed manifests).

## Dev

    cd zig
    zig build test
    zig build -Doptimize=ReleaseFast     # zig-out/bin/rad_lambda

radcore resolves via a relative path dep to the sibling checkout
`~/Developer/Zig/radcore` (see `zig/build.zig.zon`); a url+hash package dep
replaces it once radcore ships. GDAL comes
from homebrew by default; override with `-Dgdal-include=... -Dgdal-lib=...`.

### Container images

Two images, because GDAL is built from source and should not be recompiled on
every app build:

    scripts/build_gdal_base.sh      # rare: rebuilds the minimal GDAL base
    scripts/build_and_push.sh       # normal: compiles the zig binary, pushes

`Dockerfile.gdal` builds GDAL 3.11.4 + PROJ 9.6.1 with just the three drivers
this lambda uses (GRIB in, MEM warp target, Parquet for obs) into `/opt/gdal`,
and emits two tags: `-build` (headers + zig toolchain) and `-runtime` (libs
only). `Dockerfile` then just compiles the binary against the first and ships
it on the second — it needs `--build-context radcore=...` for radcore.

This replaced `ghcr.io/osgeo/gdal:ubuntu-full-3.11.4`, which carried ~250
drivers, Python + numpy, HDF5, netCDF, PostgreSQL, Poppler and Xerces:
**1.85 GB -> 221 MB**, drivers registered per cold start ~250 -> 12. Parquet is
a deferred plugin (GDAL RFC 96), so the radar path never dlopens Arrow while
`hasParquetDriver()` still reports it available.

Versions are pinned to match the OSGeo image exactly because the RADs in the
bucket were minted by its warp kernel — `scripts/verify_parity.sh` cmps output
against a reference image and must stay byte-identical. See
`docs/gdal-base-image.md`.

Base-only RADs for now — mixed-phase typing (temp/dew masks) is the known
next step and changes this to a multi-input handler (port it into radcore
when it lands, not just here).


## Raster tiles (`/tiles/v1/…`)

The same image serves XYZ raster tiles rendered on demand from the RAD3
frames in the bucket (radcore `tile.zig`), meant to sit behind CloudFront
so each tile is rendered once per stamp and cached forever:

    GET /tiles/v1/<product>/<stamp>/<z>/<x>/<y>.png[?tms=1&size=512&palette=1]
    GET /tiles/v1/<product>/latest/<z>/<x>/<y>.png      -> 302 to the newest stamp
    GET /tiles/v1/<product>/manifest.json                -> the product manifest
    GET /tiles/v1/<product>/timerange                    -> {"timestamps":[ISO8601…]}

`product` is a registry id (`rads`, `obs/temperature`, …), `stamp` is
`YYYYMMDD-HHMMSS`. Zoom 0–14; XYZ y by default, `tms=1` flips it. The
function reads `RAD_TILES_ROOT` (`/vsis3/<bucket>`, the dir holding `rads/`
and `obs/`) and keeps whole frames in a warm-container cache
(`RAD_TILES_CACHE_MB`, default 256). Zoomed out the tile is a class-aware
box filter of the frame lattice; zoomed in it is the app shader's
reconstruction (Catmull-Rom, nodata-aware, radar bands kept crisp).

Local check without AWS:

    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/rad_lambda --tile <root> rads 20260712-010000 7 28 48 tile.png
    ./zig-out/bin/rad_lambda --tile <root> obs/temperature 20260901-205500 9 114 195 t.png

(`<root>` = any dir with `rads/manifest.json` + frames, e.g. the one
raydare's `scripts/serve-rad3.sh` builds.) `test/e2e_local.sh` covers the
HTTP path (200 PNG, `latest` 302, unknown product 404, timerange).

Deploy: `deploy/08-tiles.sh <distribution-id>` (a second function from the
same image with a Function URL, a cache policy keyed on path + tms/size/
palette, and a `/tiles/*` behavior on the existing distribution) and
`deploy/09-tiles-auth.sh <distribution-id> <keys-file>` (api keys in a
CloudFront KeyValueStore checked by a viewer-request function, stripped
before caching). Both are plain aws-cli and re-runnable; neither has been
run against the live account yet.

## Precip typing (rain / mixed / snow)

Radar frames carry precipitation type as well as dBZ, folded into the byte per
radcore's banding model (`recon.zig` `bandOf`/`bandByte`):

    rain   1..88     byte = dBZ
    mixed  90..168   byte = clamp(dBZ + 80,  90, 168)
    snow   170..254  byte = clamp(dBZ + 160, 170, 254)
    89, 169 and 255 are separators and are never emitted

The source depends on the region (`ptype.sourceFor`):

- **CONUS: the obs `precip_type` product** we already publish.
  `zig/src/ptype.zig` reads the newest `obs/precip_type` frame at or before the
  radar stamp (30-minute staleness limit), samples it nearest-neighbour through
  the two geotransforms, and offsets the byte. Codes map 1 rain / 2 storm →
  rain, 3 → snow, 4 sleet / 5 mixed → mixed.
- **Alaska: MRMS `PrecipFlag_00.00`**, since obs is CONUS-only. It is read from
  beside the radar grib in `noaa-mrms-pds` (same bucket, same 2-minute stamps,
  identical 0.01° grid), warped with `-r near` because the codes are
  categorical, and tried at T, T-2 and T-4 minutes. The flag for T usually lands
  about 30 s after the radar frame, so T-2 is the normal hit. MRMS has **no
  mixed or sleet class**: code 3 → snow and every other code → rain, so Alaska
  frames never carry the mixed band. There's no trigger, storage, or IAM for
  this; it's one extra ~34 KB read per Alaska frame (about 0.5 s).
  `RAD_TYPE_MRMS=0` turns it off.
- **Hawaii, Caribbean and Guam** are never typed.

Typing uses the frame's **source** stamp. A 5-minute fill written as `:05` from
`:04` radar is typed as of `:04`.

Only echo at **≥ 10 dBZ** is typed: the mixed and snow bands cannot express
below that, so typing a 3 dBZ pixel would clamp it up and invent echo. Anything
weaker, outside the source's domain, or with no source frame inside the window
stays plain dBZ. Typing is best-effort: a missing or unreadable source ships an
untyped frame rather than failing the ingest.

`RAD_TYPE_SOURCE` overrides where the obs codes come from; pointing it at a
path that does not exist disables CONUS typing without a deploy. CLI mode has no
`RAD_OUTPUT` to derive the source from, so it never types — which is why
`scripts/verify_parity.sh` output is unaffected.

One thing downstream to know before relying on this: radcore's Z-R
accumulation (`core.zig:1296`, `:1449`) squares the **raw** byte without calling
`bandNormalize`, so typed snow accumulates ~40x overweight. (The default ramp's
black entries at bytes 200..209, which made 40..49 dBZ snow render opaque black,
were fixed in radcore `2158672`.)

## RAD3 output

Both producers write RAD3 (radcore `docs/rad-format.md`): radar warps since
2026-09-11 (CONUS ≈ 0.53 MB vs 0.73 MB RAD2 on the test grib, byte-identical
to `bench --rad3` re-encoding the RAD2 output) and obs products since the
same day. `RAD_RAD3=0` on a function falls back to RAD2; clients decode both.
