#!/bin/bash
# API keys for the tile URL, checked AT THE EDGE so cached hits are gated too:
# a CloudFront KeyValueStore holds the keys, a viewer-request CloudFront
# Function looks up `api_key` (query) or `Authorization: Bearer …`, rejects
# with 401, and strips the key so the cache key stays path + render params.
# The function's source is deploy/tile-auth.js (edit it there, then re-run).
#
#   deploy/09-tiles-auth.sh <distribution-id> <keys-file>
# keys-file: one "<key> <customer-label>" per line (never commit it).
# Re-runnable: replaces the KVS contents and republishes the function.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh
DIST_ID="${1:?usage: 09-tiles-auth.sh <distribution-id> <keys-file>}"
KEYS_FILE="${2:?usage: 09-tiles-auth.sh <distribution-id> <keys-file>}"
KVS_NAME="${FUNCTION_NAME}-tile-keys"
FN_NAME="${FUNCTION_NAME}-tile-auth"

echo "== key-value store"
KVS_ARN=$(aws cloudfront describe-key-value-store --name "$KVS_NAME" --query 'KeyValueStore.ARN' --output text 2>/dev/null || true)
if [ -z "$KVS_ARN" ] || [ "$KVS_ARN" = "None" ]; then
  KVS_ARN=$(aws cloudfront create-key-value-store --name "$KVS_NAME" --comment "tile api keys" --query 'KeyValueStore.ARN' --output text)
  sleep 5
fi
# replace contents: put every key from the file, delete the rest
KVS_ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text)
EXISTING=$(aws cloudfront-keyvaluestore list-keys --kvs-arn "$KVS_ARN" --query 'Items[].Key' --output text 2>/dev/null || true)
PUTS=$(awk 'NF{printf "{\"Key\":\"%s\",\"Value\":\"%s\"},", $1, ($2?$2:"key")}' "$KEYS_FILE" | sed 's/,$//')
DELS=""
for k in $EXISTING; do grep -q "^$k\b" "$KEYS_FILE" || DELS+="{\"Key\":\"$k\"},"; done
DELS=${DELS%,}
aws cloudfront-keyvaluestore update-keys --kvs-arn "$KVS_ARN" --if-match "$KVS_ETAG" \
  --puts "[$PUTS]" ${DELS:+--deletes "[$DELS]"} >/dev/null
echo "keys loaded: $(wc -l < "$KEYS_FILE")"

echo "== viewer-request function"
# Source lives in tile-auth.js next to this script (we cd'd here above) so the
# edge auth logic is reviewable and diffable on its own -- it is the thing
# standing between the internet and the bucket.
FN_SRC="tile-auth.js"
[ -f "$FN_SRC" ] || { echo "missing $FN_SRC beside $0" >&2; exit 1; }
CONFIG="{\"Comment\":\"tile api keys\",\"Runtime\":\"cloudfront-js-2.0\",\"KeyValueStoreAssociations\":{\"Quantity\":1,\"Items\":[{\"KeyValueStoreARN\":\"${KVS_ARN}\"}]}}"
if aws cloudfront describe-function --name "$FN_NAME" >/dev/null 2>&1; then
  FETAG=$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)
  FETAG=$(aws cloudfront update-function --name "$FN_NAME" --if-match "$FETAG" --function-config "$CONFIG" \
    --function-code fileb://"$FN_SRC" --query ETag --output text)
else
  FETAG=$(aws cloudfront create-function --name "$FN_NAME" --function-config "$CONFIG" \
    --function-code fileb://"$FN_SRC" --query ETag --output text)
fi
aws cloudfront publish-function --name "$FN_NAME" --if-match "$FETAG" >/dev/null
FN_ARN=$(aws cloudfront describe-function --name "$FN_NAME" --stage LIVE --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)

echo "== associate with the /tiles/* behavior"
aws cloudfront get-distribution-config --id "$DIST_ID" > /tmp/dist.json
ETAG=$(python3 -c "import json;print(json.load(open('/tmp/dist.json'))['ETag'])")
python3 - "$FN_ARN" <<'PY'
import json, sys
arn = sys.argv[1]
d = json.load(open('/tmp/dist.json'))['DistributionConfig']
for b in d.get('CacheBehaviors', {}).get('Items', []):
    if b['PathPattern'] == '/tiles/*':
        b['FunctionAssociations'] = {"Quantity": 1, "Items": [{"FunctionARN": arn, "EventType": "viewer-request"}]}
json.dump(d, open('/tmp/dist-new.json', 'w'))
PY
aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
  --distribution-config file:///tmp/dist-new.json --query 'Distribution.Status' --output text
echo "tile auth live: requests without a valid api_key get 401 at the edge"
