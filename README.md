# rad_lambda

S3-triggered lambda: MRMS precip grib2(.gz) in, RAD file out.

Pipeline (all in-process, no temp files): open via GDAL VSI
(`/vsigzip/`, `/vsis3/`) → `GDALWarp` to EPSG:3857 at a fixed pixel density
(1222.8 m/px, prod CONUS) into a `MEM` dataset → band 1 as bytes →
RLE-encoded RAD → written via VSI (local path or `/vsis3/bucket/prefix`).

The RAD format and RLE match `tiles`' `TileDataset#save_to_file` byte-for-byte
(golden-tested against the data_manager pipeline).

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
  path after the bucket, e.g. `/rads`).
- **CLI**: `rad_lambda <grib(.gz) | dir> [out_dir]` for local testing.

## Dev

    shards install   # uses shard.override.yml -> ../lib_gdal until pushed
    crystal spec --link-flags "-Wl,-rpath,/usr/local/lib"   # rpath: see below
    shards build

If specs die with `Library not loaded: @rpath/libgdal...`, the temp binary
lacks an rpath to your GDAL — pass `--link-flags "-Wl,-rpath,$(gdal-config
--prefix)/lib"` as above.

Requires GDAL (`brew install gdal`; make sure a working gdal-config is first
on PATH). Base-only RADs for now — mixed-phase typing (temp/dew masks) is the
known next step and changes this to a multi-input handler.
