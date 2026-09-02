#!/bin/bash
# Full local end-to-end test of the rad-lambda container:
#
#   MinIO (S3 stand-in) <- seeded with real MRMS gribs
#   aws-lambda-rie      -> drives the container's ACTUAL runtime loop
#   curl                -> posts S3 events (on-grid + off-grid)
#   assertions          -> RAD + manifest exist, gzipped w/ Content-Encoding,
#                          RAD bytes identical to the same binary in CLI mode
#
# Usage: test/e2e_local.sh [image-tag]   (default rad-lambda:local)
# Requires: docker, a grib dir (GRIB_DIR below), network for the one-time
# RIE binary download (cached in test/.cache).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-rad-lambda:local}"
GRIB_DIR="${GRIB_DIR:-/Users/cmorello/Developer/crystal/git/data_manager/.claude/worktrees/dataset-refactor/temp/raw_gribs/conus}"
NET=radlambda-e2e
MINIO=radlambda-e2e-minio
LAMBDA=radlambda-e2e-fn
OBSFN=radlambda-e2e-obs
RIE_CACHE=test/.cache
WORK=$(mktemp -d /tmp/radlambda-e2e.XXXXXX)

cleanup() {
  docker rm -f "$MINIO" "$LAMBDA" "$OBSFN" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- pick test gribs: first on-grid (MM0 00) and first off-grid stamp -------
ON_GRIB=$(ls "$GRIB_DIR"/*.grib2.gz | grep "[0-9]\{8\}-[0-9]\{2\}[0-9]000\.grib2\.gz" | head -1)
[ -n "$ON_GRIB" ] || fail "no on-grid grib found in $GRIB_DIR"
ON_NAME=$(basename "$ON_GRIB")
ON_STAMP=$(echo "$ON_NAME" | grep -o "[0-9]\{8\}-[0-9]\{6\}")
OFF_NAME="${ON_NAME/$ON_STAMP/${ON_STAMP:0:13}200}" # minute xx2 -> off-grid

# --- RIE binary (arm64, cached) ----------------------------------------------
mkdir -p "$RIE_CACHE"
RIE="$RIE_CACHE/aws-lambda-rie-arm64"
if [ ! -x "$RIE" ]; then
  echo "downloading aws-lambda-rie..."
  curl -fsSL -o "$RIE" \
    https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/latest/download/aws-lambda-rie-arm64
  chmod +x "$RIE"
fi

# --- minio: bucket layout mirrors prod (noaa bucket + output bucket) --------
docker network create "$NET" >/dev/null
docker run -d --rm --name "$MINIO" --network "$NET" \
  -e MINIO_ROOT_USER=e2e -e MINIO_ROOT_PASSWORD=e2esecret \
  minio/minio server /data >/dev/null
for i in $(seq 1 30); do
  docker exec "$MINIO" mc alias set local http://localhost:9000 e2e e2esecret >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$MINIO" mc mb local/noaa-mrms-pds local/rad-output >/dev/null
docker cp "$ON_GRIB" "$MINIO":/tmp/on.gz
docker exec "$MINIO" mc cp /tmp/on.gz "local/noaa-mrms-pds/CONUS/SeamlessHSR_00.00/$ON_NAME" >/dev/null
docker exec "$MINIO" mc cp /tmp/on.gz "local/noaa-mrms-pds/CONUS/SeamlessHSR_00.00/$OFF_NAME" >/dev/null

# --- lambda container under RIE ----------------------------------------------
docker run -d --rm --name "$LAMBDA" --network "$NET" -p 9080:8080 \
  -v "$(pwd)/$RIE:/rie:ro" --entrypoint /rie \
  -e AWS_ACCESS_KEY_ID=e2e -e AWS_SECRET_ACCESS_KEY=e2esecret \
  -e AWS_S3_ENDPOINT="$MINIO:9000" -e AWS_HTTPS=NO -e AWS_VIRTUAL_HOSTING=FALSE \
  -e RAD_OUTPUT=/vsis3/rad-output/rads -e RAD_URL_PREFIX=/rads \
  -e RAD_MANIFEST_HOURS=0 \
  "$IMAGE" /var/runtime/bootstrap >/dev/null
sleep 2

invoke() {
  curl -sf -XPOST http://localhost:9080/2015-03-31/functions/function/invocations -d "$1"
}
event() {
  printf '{"Records":[{"s3":{"bucket":{"name":"noaa-mrms-pds"},"object":{"key":"CONUS/SeamlessHSR_00.00/%s"}}}]}' "$1"
}

# --- 1: on-grid event processes ----------------------------------------------
R1=$(invoke "$(event "$ON_NAME")")
echo "on-grid  -> $R1"
echo "$R1" | grep -q "\"processed\":\[\"/vsis3/rad-output/rads/$ON_STAMP.rad\"\]" || fail "unexpected on-grid response"

# --- 2: off-grid event skips ---------------------------------------------------
R2=$(invoke "$(event "$OFF_NAME")")
echo "off-grid -> $R2"
echo "$R2" | grep -q '"processed":\[\],"skipped":1' || fail "off-grid event was not skipped"

# --- 2b: a key with no producer skips instead of failing the batch ----------
R2B=$(invoke '{"Records":[{"s3":{"bucket":{"name":"noaa-mrms-pds"},"object":{"key":"CONUS/SeamlessHSR_00.00/_SUCCESS"}}}]}')
echo "unroutable -> $R2B"
echo "$R2B" | grep -q '"processed":\[\],"skipped":1' || fail "unroutable key was not skipped"

# --- 3: outputs exist, gzipped, with Content-Encoding metadata ---------------
docker exec "$MINIO" mc stat "local/rad-output/rads/$ON_STAMP.rad" > "$WORK/stat_rad" 2>&1
docker exec "$MINIO" mc stat local/rad-output/rads/manifest.json > "$WORK/stat_manifest" 2>&1
grep -qi "Content-Encoding.*gzip" "$WORK/stat_rad" || fail "rad missing Content-Encoding: gzip"
grep -qi "Content-Encoding.*gzip" "$WORK/stat_manifest" || fail "manifest missing Content-Encoding: gzip"

docker exec "$MINIO" mc cat "local/rad-output/rads/$ON_STAMP.rad" > "$WORK/out.rad.gz"
docker exec "$MINIO" mc cat local/rad-output/rads/manifest.json > "$WORK/manifest.json.gz"
gunzip -c "$WORK/out.rad.gz" > "$WORK/out.rad"
gunzip -c "$WORK/manifest.json.gz" > "$WORK/manifest.json"

head -c4 "$WORK/out.rad" | grep -q "RAD2" || fail "rad missing RAD2 magic"
grep -q "\"url\":\"/rads/$ON_STAMP.rad\"" "$WORK/manifest.json" || fail "manifest missing frame url"
grep -q '"product":"reflectivity"' "$WORK/manifest.json" || fail "manifest product wrong"

# --- 4: byte parity vs the SAME binary in CLI mode (same GDAL, no gzip) ------
mkdir -p "$WORK/cli"
docker run --rm --entrypoint /var/runtime/bootstrap \
  -v "$GRIB_DIR:/in:ro" -v "$WORK/cli:/out" "$IMAGE" "/in/$ON_NAME" /out >/dev/null
cmp "$WORK/out.rad" "$WORK/cli/$ON_STAMP.rad" || fail "lambda-mode RAD differs from CLI-mode RAD"

# --- 5: obs (H3 parquet) through a SECOND function on the same image --------
# Mirrors production: obs is its own lambda with RAD_OUTPUT at the BUCKET ROOT,
# so obs.ingest lands at /obs/{variable}/ as a sibling of /rads/ and the
# manifest url prefix it hardcodes (/obs/{variable}) is the real serving path.
OBS_PARQUET="${OBS_PARQUET:-$HOME/Developer/Swift/Playgrounds/raydare/data-research/1788296100_slim.parquet}"
OBS_NAME=$(basename "$OBS_PARQUET")
OBS_EPOCH=$(echo "$OBS_NAME" | grep -oE '^[0-9]{10}' || true)

if [ ! -f "$OBS_PARQUET" ] || [ -z "$OBS_EPOCH" ]; then
  echo "obs: skipped (set OBS_PARQUET to a 10-digit-epoch .parquet to enable)"
  echo "E2E PASS: process + skip + gzip metadata + manifest + byte parity"
  exit 0
fi
OBS_STAMP=$(date -u -r "$OBS_EPOCH" +%Y%m%d-%H%M%S)

docker exec "$MINIO" mc mb local/obs-input >/dev/null 2>&1 || true
docker cp "$OBS_PARQUET" "$MINIO":/tmp/obs.parquet
docker exec "$MINIO" mc cp /tmp/obs.parquet "local/obs-input/gcc/output/$OBS_NAME" >/dev/null

docker run -d --rm --name "$OBSFN" --network "$NET" -p 9081:8080 \
  -v "$(pwd)/$RIE:/rie:ro" --entrypoint /rie \
  -e AWS_ACCESS_KEY_ID=e2e -e AWS_SECRET_ACCESS_KEY=e2esecret \
  -e AWS_S3_ENDPOINT="$MINIO:9000" -e AWS_HTTPS=NO -e AWS_VIRTUAL_HOSTING=FALSE \
  -e RAD_OUTPUT=/vsis3/rad-output -e RAD_MANIFEST_HOURS=0 \
  "$IMAGE" /var/runtime/bootstrap >/dev/null
sleep 2

R5=$(curl -sf -XPOST http://localhost:9081/2015-03-31/functions/function/invocations \
  -d "$(printf '{"Records":[{"s3":{"bucket":{"name":"obs-input"},"object":{"key":"gcc/output/%s"}}}]}' "$OBS_NAME")")
echo "obs -> $(echo "$R5" | cut -c1-110)..."

# 13 products + the wind .flw sidecar
COUNT=$(echo "$R5" | grep -o '\.rad"' | wc -l | tr -d ' ')
[ "$COUNT" = "13" ] || fail "expected 13 obs .rad outputs, got $COUNT"
echo "$R5" | grep -q "/vsis3/rad-output/obs/temperature/$OBS_STAMP.rad" || fail "obs temperature path missing"
echo "$R5" | grep -q "/vsis3/rad-output/obs/wind_average/$OBS_STAMP.flw" || fail "obs wind .flw missing"

# THE regression test for the gzip bug: main.zig marks the whole RAD_OUTPUT
# prefix gzip, so a plain body here would be tagged Content-Encoding: gzip and
# be undecodable. Assert the header AND that the body actually inflates.
docker exec "$MINIO" mc stat "local/rad-output/obs/temperature/$OBS_STAMP.rad" > "$WORK/stat_obs" 2>&1
grep -qi "Content-Encoding.*gzip" "$WORK/stat_obs" || fail "obs rad missing Content-Encoding: gzip"
docker exec "$MINIO" mc cat "local/rad-output/obs/temperature/$OBS_STAMP.rad" > "$WORK/obs.rad.gz"
gunzip -c "$WORK/obs.rad.gz" > "$WORK/obs.rad" || fail "obs rad is tagged gzip but does not inflate"
head -c4 "$WORK/obs.rad" | grep -q "RAD2" || fail "obs rad missing RAD2 magic"

docker exec "$MINIO" mc stat local/rad-output/obs/temperature/manifest.json > "$WORK/stat_obs_m" 2>&1
grep -qi "Content-Encoding.*gzip" "$WORK/stat_obs_m" || fail "obs manifest missing Content-Encoding: gzip"
docker exec "$MINIO" mc cat local/rad-output/obs/temperature/manifest.json > "$WORK/obs_manifest.gz"
gunzip -c "$WORK/obs_manifest.gz" > "$WORK/obs_manifest.json" || fail "obs manifest tagged gzip but does not inflate"
grep -q '"product":"temperature"' "$WORK/obs_manifest.json" || fail "obs manifest product wrong"
grep -q "\"url\":\"/obs/temperature/$OBS_STAMP.rad\"" "$WORK/obs_manifest.json" || fail "obs manifest url wrong"

# The radar manifest must NOT have been touched by an obs-only invocation.
docker exec "$MINIO" mc cat local/rad-output/obs/manifest.json >/dev/null 2>&1 \
  && fail "obs wrote a stray manifest at the obs/ root"

echo "obs -> 13 products + .flw, gzipped and inflating, manifests correct"

# --- 6: WARM container sees an object that arrived after the first open -----
# Regression guard for GDAL_DISABLE_READDIR_ON_OPEN (set in Dockerfile.gdal).
# Without it, GDAL lists the parent prefix on open and vsicurl caches that
# listing for the life of the process, so the SECOND invocation of a warm
# container fails with OpenFailed on any newly-arrived key. At a 5-minute
# cadence that is nearly every invocation. Copy the same parquet under an
# epoch 300 s later, i.e. the real cadence, AFTER the container has already
# listed the prefix once.
OBS_EPOCH2=$((OBS_EPOCH + 300))
OBS_STAMP2=$(date -u -r "$OBS_EPOCH2" +%Y%m%d-%H%M%S)
docker exec "$MINIO" mc cp /tmp/obs.parquet "local/obs-input/gcc/output/${OBS_EPOCH2}_slim.parquet" >/dev/null

R6=$(curl -sf -XPOST http://localhost:9081/2015-03-31/functions/function/invocations \
  -d "$(printf '{"Records":[{"s3":{"bucket":{"name":"obs-input"},"object":{"key":"gcc/output/%s_slim.parquet"}}}]}' "$OBS_EPOCH2")")
echo "warm -> $(echo "$R6" | cut -c1-100)..."
echo "$R6" | grep -q "OpenFailed" \
  && fail "warm container could not see a newly-arrived object (GDAL_DISABLE_READDIR_ON_OPEN missing?)"
echo "$R6" | grep -q "/vsis3/rad-output/obs/temperature/$OBS_STAMP2.rad" \
  || fail "warm-container obs invocation did not produce the expected frame"

echo "E2E PASS: radar + skip + gzip metadata + manifest + byte parity + obs + warm reuse"
