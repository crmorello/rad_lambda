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

for region in "${REGION_PREFIXES[@]}"; do
  for day in $(date -u -v-1d +%Y%m%d 2>/dev/null || date -u -d yesterday +%Y%m%d) $(date -u +%Y%m%d); do
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
      aws lambda invoke --function-name "$FUNCTION_NAME" \
        --invocation-type Event \
        --payload "$(echo "{\"Records\":[{\"s3\":{\"bucket\":{\"name\":\"${NOAA_BUCKET}\"},\"object\":{\"key\":\"${key}\"}}}]}" | base64)" \
        /dev/null >/dev/null
    done
  done
done
echo "backfill dispatched (async). Watch: aws logs tail /aws/lambda/${FUNCTION_NAME} --follow"
