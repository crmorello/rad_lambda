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
RIE_CACHE=test/.cache
WORK=$(mktemp -d /tmp/radlambda-e2e.XXXXXX)

cleanup() {
  docker rm -f "$MINIO" "$LAMBDA" >/dev/null 2>&1 || true
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

echo "E2E PASS: process + skip + gzip metadata + manifest + byte parity"
