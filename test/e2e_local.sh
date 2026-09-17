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
  docker rm -f "$MINIO" "$LAMBDA" "$OBSFN" radlambda-e2e-tiles >/dev/null 2>&1 || true
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
  -e RAD_TILES_ROOT=/vsis3/rad-output \
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

head -c4 "$WORK/out.rad" | grep -q "RAD3" || fail "rad missing RAD3 magic"
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
  -e RAD_KEY_PREFIXES=gcc/output/ \
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
head -c4 "$WORK/obs.rad" | grep -q "RAD3" || fail "obs rad missing RAD3 magic"

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

# --- 7: a parquet OUTSIDE the allow-listed prefix is skipped ---------------
# The obs producer invokes the function on every write to its bucket, not just
# gcc/output/, and kindForKey routes on extension alone — so without
# RAD_KEY_PREFIXES a stray parquet anywhere in that bucket would be ingested as
# an obs issuance and publish 13 bogus products.
docker exec "$MINIO" mc cp /tmp/obs.parquet "local/obs-input/uploads/$OBS_NAME" >/dev/null
R7=$(curl -sf -XPOST http://localhost:9081/2015-03-31/functions/function/invocations \
  -d "$(printf '{"Records":[{"s3":{"bucket":{"name":"obs-input"},"object":{"key":"uploads/%s"}}}]}' "$OBS_NAME")")
echo "off-prefix -> $R7"
echo "$R7" | grep -q '"processed":\[\],"skipped":1' || fail "parquet outside RAD_KEY_PREFIXES was not skipped"
docker exec "$MINIO" mc ls local/rad-output/obs/temperature/ 2>/dev/null | grep -q "$OBS_STAMP.rad" \
  || fail "sanity: the in-prefix frame should still exist"

# --- 8: raster tiles from the same container (function-URL HTTP events) ----
# A z5 tile over the central US for the ingested stamp must be a PNG; `latest`
# must redirect to that stamp; an unknown product is a 404. Tiles render from
# the RAD frames just written to MinIO (RAD_TILES_ROOT = bucket root).
http_event() { printf '{"rawPath":"%s","rawQueryString":"","queryStringParameters":{}}' "$1"; }
T1=$(invoke "$(http_event "/tiles/v1/rads/$ON_STAMP/5/7/12.png")")
echo "tile -> $(echo "$T1" | cut -c1-120)..."
echo "$T1" | grep -q '"statusCode":200' || fail "tile request did not return 200"
echo "$T1" | grep -q '"Content-Type":"image/png"' || fail "tile content type"
echo "$T1" | grep -q 'max-age=31536000, immutable' || fail "tile cache-control"
echo "$T1" | sed -n 's/.*"body":"\([^"]*\)".*/\1/p' | base64 -d | head -c 4 | od -An -c | grep -q "211   P   N   G" \
  || fail "tile body is not a PNG"
T2=$(invoke "$(http_event "/tiles/v1/rads/latest/5/7/12.png")")
echo "$T2" | grep -q '"statusCode":302' || fail "latest did not redirect"
echo "$T2" | grep -q "\"Location\":\"/tiles/v1/rads/$ON_STAMP/5/7/12.png\"" || fail "latest redirected to the wrong stamp"
T3=$(invoke "$(http_event "/tiles/v1/nope/$ON_STAMP/5/7/12.png")")
echo "$T3" | grep -q '"statusCode":404' || fail "unknown product was not a 404"
T4=$(invoke "$(http_event "/tiles/v1/rads/timerange")")
# respond() JSON-escapes the body, so the payload reads \"timestamps\":[ .
echo "$T4" | grep -q '\\"timestamps\\":\[' || fail "timerange shape"

# --- 9: the tile function in ITS OWN configuration -------------------------
# deploy/08-tiles.sh sets RAD_TILES_ROOT only — no RAD_OUTPUT, because the tile
# function never writes. Cases 1-8 all ran against the ingest container, which
# sets RAD_OUTPUT, so they could not catch an init that requires it. This runs
# the container the way the deploy script actually configures it.
TILEFN=radlambda-e2e-tiles
docker run -d --rm --name "$TILEFN" --network "$NET" -p 9082:8080 \
  -v "$(pwd)/$RIE:/rie:ro" --entrypoint /rie \
  -e AWS_ACCESS_KEY_ID=e2e -e AWS_SECRET_ACCESS_KEY=e2esecret \
  -e AWS_S3_ENDPOINT="$MINIO:9000" -e AWS_HTTPS=NO -e AWS_VIRTUAL_HOSTING=FALSE \
  -e RAD_TILES_ROOT=/vsis3/rad-output -e RAD_TILES_CACHE_MB=384 \
  "$IMAGE" /var/runtime/bootstrap >/dev/null
sleep 3
T5=$(curl -sf -XPOST http://localhost:9082/2015-03-31/functions/function/invocations \
  -d "$(printf '{"rawPath":"/tiles/v1/rads/%s/5/7/12.png","queryStringParameters":{}}' "$ON_STAMP")")
echo "tiles-only -> $(echo "$T5" | cut -c1-90)..."
docker logs "$TILEFN" 2>&1 | grep -q "MissingRadOutput" \
  && fail "tile function needs RAD_OUTPUT to start — it has no output dir"
echo "$T5" | grep -q '"statusCode":200' || fail "tiles-only container did not serve a tile"
docker rm -f "$TILEFN" >/dev/null 2>&1

# --- 10: 5-minute tile fills ------------------------------------------------
# MRMS publishes every 2 min; the tile timeline wants :00,:05,:10,… The :00/:10
# frames stay the 10-minute series in rads/ (written ONCE). The in-between slot
# comes from :04, or :06 as a fallback, relabelled to :05 and written to
# rads/5min/. The local grib set is 10-minute only, and the handler takes the
# stamp from the FILENAME, so synthesize the sources by copying.
FILL_SRC=$(echo "$ON_NAME" | sed -E 's/-[0-9]{6}\.grib2\.gz$/-010400.grib2.gz/')
FILL_SIX=$(echo "$ON_NAME" | sed -E 's/-[0-9]{6}\.grib2\.gz$/-010600.grib2.gz/')
FILL_TWO=$(echo "$ON_NAME" | sed -E 's/-[0-9]{6}\.grib2\.gz$/-010200.grib2.gz/')
for n in "$FILL_SRC" "$FILL_SIX" "$FILL_TWO"; do
  docker exec "$MINIO" mc cp /tmp/on.gz "local/noaa-mrms-pds/CONUS/SeamlessHSR_00.00/$n" >/dev/null
done

R10=$(invoke "$(event "$FILL_SRC")")
echo ":04 -> $R10"
echo "$R10" | grep -q '"processed":\["/vsis3/rad-output/rads/5min/20260712-010500.rad"\]' \
  || fail ":04 did not produce the 20260712-010500 fill"

# The relabel must reach the RAD header, not just the filename.
docker exec "$MINIO" mc cat local/rad-output/rads/5min/20260712-010500.rad > "$WORK/fill.gz"
gunzip -c "$WORK/fill.gz" > "$WORK/fill.rad" || fail "fill is not gzipped at rest"
python3 - "$WORK/fill.rad" <<'PYEOF'
import struct, sys, datetime
d = open(sys.argv[1], 'rb').read()
assert d[:4] in (b'RAD2', b'RAD3'), d[:4]
t = datetime.datetime.fromtimestamp(struct.unpack('<q', d[4:12])[0] / 1000, datetime.timezone.utc)
assert t.strftime('%Y%m%d-%H%M%S') == '20260712-010500', f'header time is {t}, want 20260712-010500'
print("    header time relabelled to 20260712-010500")
PYEOF

# The 10-minute series must be untouched: no new object, no new manifest entry.
docker exec "$MINIO" mc ls local/rad-output/rads/ | grep -q "20260712-010500.rad" \
  && fail "a 5-minute fill leaked into rads/"
docker exec "$MINIO" mc cat local/rad-output/rads/manifest.json > "$WORK/m10.gz"
gunzip -c "$WORK/m10.gz" > "$WORK/m10.json"
grep -q "010500" "$WORK/m10.json" && fail "5-minute fill leaked into the 10-minute manifest"

# The tile timeline interleaves both prefixes without duplicating either.
docker exec "$MINIO" mc cat local/rad-output/rads/5min/manifest.json > "$WORK/m5.gz"
gunzip -c "$WORK/m5.gz" > "$WORK/m5.json"
grep -q '"url":"/rads/5min/20260712-010500.rad"' "$WORK/m5.json" || fail "merged manifest missing the fill url"
grep -q "\"url\":\"/rads/$ON_STAMP.rad\"" "$WORK/m5.json" || fail "merged manifest missing the 10-minute url"

# :06 must yield to the :04 that already filled the slot.
R10B=$(invoke "$(event "$FILL_SIX")")
echo ":06 (slot filled) -> $R10B"
echo "$R10B" | grep -q '"processed":\[\],"skipped":1' || fail ":06 overwrote a slot :04 had already filled"

# ...but must fill it when :04 never landed.
docker exec "$MINIO" mc rm local/rad-output/rads/5min/20260712-010500.rad >/dev/null
R10C=$(invoke "$(event "$FILL_SIX")")
echo ":06 (slot empty)  -> $R10C"
echo "$R10C" | grep -q '"processed":\["/vsis3/rad-output/rads/5min/20260712-010500.rad"\]' \
  || fail ":06 did not fill an empty slot"

# :02 is never a source.
R10D=$(invoke "$(event "$FILL_TWO")")
echo ":02 -> $R10D"
echo "$R10D" | grep -q '"processed":\[\],"skipped":1' || fail ":02 should never produce a fill"

# --- 11: precip typing from obs precip_type --------------------------------
# The radar container reads obs/precip_type out of the SAME bucket it writes to
# (sourceDir derives it from RAD_OUTPUT's parent). Case 5 already produced a
# precip_type frame, but months away from the radar grib -- restamp a copy so it
# lands inside the 30-minute window, then reprocess the same grib.
PT_STAMP=$(date -u -r $(( $(date -u -j -f "%Y%m%d-%H%M%S" "$ON_STAMP" +%s) - 300 )) +%Y%m%d-%H%M%S)
docker exec "$MINIO" mc cp "local/rad-output/obs/precip_type/$OBS_STAMP.rad" \
  "local/rad-output/obs/precip_type/$PT_STAMP.rad" >/dev/null
PT_BYTES=$(docker exec "$MINIO" mc stat --json "local/rad-output/obs/precip_type/$PT_STAMP.rad" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["size"])')
printf '{"product":"precip_type","frames":[{"id":"%s","url":"/obs/precip_type/%s.rad","bytes":%s}]}' \
  "$PT_STAMP" "$PT_STAMP" "$PT_BYTES" > "$WORK/pt_manifest.json"
docker cp "$WORK/pt_manifest.json" "$MINIO":/tmp/ptm.json >/dev/null
docker exec "$MINIO" mc cp /tmp/ptm.json local/rad-output/obs/precip_type/manifest.json >/dev/null

docker exec "$MINIO" mc cat "local/rad-output/rads/$ON_STAMP.rad" > "$WORK/untyped.gz"
# Read the log delta by line offset, NOT by diff: diff exits 1 when the files
# differ, which under `set -o pipefail` kills the script on the very case we
# are testing for.
LOG_N=$(docker logs "$LAMBDA" 2>&1 | wc -l | tr -d " ")
R11=$(invoke "$(event "$ON_NAME")")
echo "typed -> $R11"
docker logs "$LAMBDA" 2>&1 | tail -n +$((LOG_N + 1)) > "$WORK/log_delta.txt"
grep -oE "typed [0-9]+ px from obs precip_type" "$WORK/log_delta.txt" | tail -1 || true

TYPED_N=$(grep -oE "typed [0-9]+ px" "$WORK/log_delta.txt" | grep -oE "[0-9]+" | tail -1 || true)
[ -n "$TYPED_N" ] && [ "$TYPED_N" -gt 0 ] || fail "precip typing applied to 0 pixels (expected > 0)"

# The frame must actually have changed on disk.
docker exec "$MINIO" mc cat "local/rad-output/rads/$ON_STAMP.rad" > "$WORK/typed.gz"
cmp -s "$WORK/untyped.gz" "$WORK/typed.gz" && fail "typed frame is byte-identical to the untyped one"

# Stale obs must fail SAFE: same grib, a manifest 31 minutes out, no typing.
PT_OLD=$(date -u -r $(( $(date -u -j -f "%Y%m%d-%H%M%S" "$ON_STAMP" +%s) - 1860 )) +%Y%m%d-%H%M%S)
docker exec "$MINIO" mc cp "local/rad-output/obs/precip_type/$PT_STAMP.rad" \
  "local/rad-output/obs/precip_type/$PT_OLD.rad" >/dev/null
docker exec "$MINIO" mc rm "local/rad-output/obs/precip_type/$PT_STAMP.rad" >/dev/null
printf '{"product":"precip_type","frames":[{"id":"%s","url":"/obs/precip_type/%s.rad","bytes":%s}]}' \
  "$PT_OLD" "$PT_OLD" "$PT_BYTES" > "$WORK/pt_old.json"
docker cp "$WORK/pt_old.json" "$MINIO":/tmp/pto.json >/dev/null
docker exec "$MINIO" mc cp /tmp/pto.json local/rad-output/obs/precip_type/manifest.json >/dev/null

LOG_N2=$(docker logs "$LAMBDA" 2>&1 | wc -l | tr -d " ")
invoke "$(event "$ON_NAME")" >/dev/null
docker logs "$LAMBDA" 2>&1 | tail -n +$((LOG_N2 + 1)) > "$WORK/log_delta2.txt"
grep -q "no precip_type frame within 30 min" "$WORK/log_delta2.txt" \
  || fail "a 31-minute-old precip_type frame was not rejected"
echo "stale obs -> rejected, frame ships untyped"

echo "E2E PASS: radar + skip + gzip metadata + manifest + byte parity + obs + warm reuse + prefix filter + tiles + tiles-only + 5-min fills + precip typing"
