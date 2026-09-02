# rad_lambda

S3-triggered lambda: MRMS precip grib2(.gz) in, RAD file out.

**Implementation: Zig (`zig/`), sharing radcore with raydare** (§14 one
language, all layers): the RAD v2 encoder lives in
`raydare/radcore/src/core.zig` next to the decoder the client renders from —
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
  SNS->Lambda, or raw S3 events. Per record: skips stamps off the 10-minute
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
- **CLI**: `rad_lambda <grib(.gz) | dir> [out_dir]` for local testing
  (plain files, no gzip, no manifest).

## Dev

    cd zig
    zig build test
    zig build -Doptimize=ReleaseFast     # zig-out/bin/rad_lambda

radcore resolves via a relative path dep to
`~/Developer/Swift/Playgrounds/raydare/radcore` (see `zig/build.zig.zon`) —
extract radcore to its own repo to durably break that coupling. GDAL comes
from homebrew by default; override with `-Dgdal-include=... -Dgdal-lib=...`.

Docker image (the deployable): see `Dockerfile` — needs
`--build-context radcore=...` for radcore.

Base-only RADs for now — mixed-phase typing (temp/dew masks) is the known
next step and changes this to a multi-input handler (port it into radcore
when it lands, not just here).
