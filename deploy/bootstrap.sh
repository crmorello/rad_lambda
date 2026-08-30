#!/bin/bash
# Backfill: on first deploy the bucket is empty — list the last 3h of
# on-grid SeamlessHSR objects per region from NOAA and feed each through the
# DEPLOYED Lambda via a synthesized S3 event (same code path as live
# notifications; idempotent — reprocessing a key rewrites the same object).
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

HOURS="${1:-3}"
NOW=$(date -u +%s)
CUTOFF=$((NOW - HOURS * 3600))

# Every UTC day folder from cutoff to now (was: hardcoded yesterday+today,
# which silently capped backfills at ~48h regardless of HOURS).
DAYS=""
t=$CUTOFF
while [ "$t" -le "$NOW" ]; do
  DAYS="$DAYS $(date -u -r "$t" +%Y%m%d 2>/dev/null || date -u -d "@$t" +%Y%m%d)"
  t=$((t + 86400))
done
DAYS="$DAYS $(date -u +%Y%m%d)"
DAYS=$(echo "$DAYS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

for region in "${REGION_PREFIXES[@]}"; do
  for day in $DAYS; do
    prefix="${region}/SeamlessHSR_00.00/${day}/"
    aws s3api list-objects-v2 --bucket "$NOAA_BUCKET" --prefix "$prefix" \
      --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n' | while read -r key; do
      [ -z "$key" ] && continue
      stamp=$(echo "$key" | grep -oE '[0-9]{8}-[0-9]{6}' | tail -1)
      [ -z "$stamp" ] && continue
      min=${stamp:11:2}; sec=${stamp:13:2}
      # 10-minute grid only (mirrors the handler gate — skip the rest here
      # to avoid paying an invocation per no-op)
      [ $((10#$min % 10)) -ne 0 ] && continue
      [ "$sec" != "00" ] && continue
      epoch=$(date -u -j -f "%Y%m%d-%H%M%S" "$stamp" +%s 2>/dev/null || \
              date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${min}:${sec}" +%s)
      [ "$epoch" -lt "$CUTOFF" ] && continue
      echo "backfill: $key"
      # Single-quoted printf template, built into a variable BEFORE the aws
      # call: macOS /bin/bash is 3.2, whose parser leaks nested double quotes
      # inside "$(...)" — the JSON's {a,b} braces then brace-expand and the
      # payload arrives as two mangled arguments. Assignment context is safe.
      payload=$(printf '{"Records":[{"s3":{"bucket":{"name":"%s"},"object":{"key":"%s"}}}]}' \
        "$NOAA_BUCKET" "$key" | base64)
      aws lambda invoke --function-name "$FUNCTION_NAME" \
        --invocation-type Event \
        --payload "$payload" /dev/null > /dev/null
    done
  done
done
echo "backfill dispatched (async). Watch: aws logs tail /aws/lambda/${FUNCTION_NAME} --follow"
