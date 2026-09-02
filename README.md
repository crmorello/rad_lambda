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
  and reproduces the unsmoothed plateaus byte-for-byte). Separate functions
  keep the two products' memory, timeout, concurrency and DLQ independent.
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
