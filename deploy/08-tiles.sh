#!/bin/bash
# The raster TILE function: same image as the ingest lambda, a second
# function with a Function URL (auth NONE — api keys are checked at the
# edge by 09-tiles-auth.sh) and a CloudFront behavior `/tiles/*` on the
# existing distribution whose origin is that URL. Tiles are immutable per
# stamp (Cache-Control from the function), so the cache policy keys on the
# path plus the three rendering query params only.
#
#   deploy/08-tiles.sh <distribution-id>
# Re-runnable: creates what is missing, updates what exists.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh
DIST_ID="${1:?usage: 08-tiles.sh <cloudfront distribution id>}"

TILES_FUNCTION="${FUNCTION_NAME}-tiles"
ROLE_NAME="${TILES_FUNCTION}-role"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

echo "== IAM role (read the output bucket, write logs)"
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name inline --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${RAD_BUCKET}\",\"arn:aws:s3:::${RAD_BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"}
  ]}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
sleep 8

echo "== function (same image; tile mode is selected by the HTTP event shape)"
ENV_VARS="Variables={RAD_TILES_ROOT=/vsis3/${RAD_BUCKET},RAD_TILES_CACHE_MB=384}"
if aws lambda get-function --function-name "$TILES_FUNCTION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$TILES_FUNCTION" --image-uri "$ECR_URI:latest" >/dev/null
  aws lambda wait function-updated --function-name "$TILES_FUNCTION"
  aws lambda update-function-configuration --function-name "$TILES_FUNCTION" \
    --memory-size 1024 --timeout 15 --environment "$ENV_VARS" >/dev/null
else
  aws lambda create-function --function-name "$TILES_FUNCTION" \
    --package-type Image --code "ImageUri=${ECR_URI}:latest" \
    --role "$ROLE_ARN" --architectures arm64 \
    --memory-size 1024 --timeout 15 --environment "$ENV_VARS" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$TILES_FUNCTION"

echo "== function URL (public; the edge function gates api keys)"
if ! aws lambda get-function-url-config --function-name "$TILES_FUNCTION" >/dev/null 2>&1; then
  aws lambda create-function-url-config --function-name "$TILES_FUNCTION" --auth-type NONE >/dev/null
  aws lambda add-permission --function-name "$TILES_FUNCTION" --statement-id url-public \
    --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE >/dev/null
fi
URL=$(aws lambda get-function-url-config --function-name "$TILES_FUNCTION" --query FunctionUrl --output text)
ORIGIN_HOST=$(echo "$URL" | sed -E 's#https?://([^/]+)/?#\1#')
echo "function url: $URL"

echo "== cache policy: path + tms/size/palette, immutable-friendly TTLs"
CP_NAME="${FUNCTION_NAME}-tiles"
CP_ID=$(aws cloudfront list-cache-policies --type custom \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='${CP_NAME}'].CachePolicy.Id | [0]" --output text 2>/dev/null || echo None)
if [ "$CP_ID" = "None" ] || [ -z "$CP_ID" ]; then
  CP_ID=$(aws cloudfront create-cache-policy --cache-policy-config "{
    \"Name\":\"${CP_NAME}\",\"Comment\":\"RAD3 raster tiles\",
    \"DefaultTTL\":86400,\"MaxTTL\":31536000,\"MinTTL\":0,
    \"ParametersInCacheKeyAndForwardedToOrigin\":{
      \"EnableAcceptEncodingGzip\":false,\"EnableAcceptEncodingBrotli\":false,
      \"HeadersConfig\":{\"HeaderBehavior\":\"none\"},
      \"CookiesConfig\":{\"CookieBehavior\":\"none\"},
      \"QueryStringsConfig\":{\"QueryStringBehavior\":\"whitelist\",\"QueryStrings\":{\"Quantity\":3,\"Items\":[\"tms\",\"size\",\"palette\"]}}
    }}" --query 'CachePolicy.Id' --output text)
fi
# forward the query string to the origin too (the function reads tms/size/palette)
ORP_ID=$(aws cloudfront list-origin-request-policies --type managed \
  --query "OriginRequestPolicyList.Items[?OriginRequestPolicy.OriginRequestPolicyConfig.Name=='Managed-AllViewerExceptHostHeader'].OriginRequestPolicy.Id | [0]" --output text)

echo "== distribution: add origin + /tiles/* behavior"
aws cloudfront get-distribution-config --id "$DIST_ID" > /tmp/dist.json
ETAG=$(python3 -c "import json;print(json.load(open('/tmp/dist.json'))['ETag'])")
python3 - "$ORIGIN_HOST" "$CP_ID" "$ORP_ID" <<'PY'
import json, sys
host, cp, orp = sys.argv[1:4]
d = json.load(open('/tmp/dist.json'))['DistributionConfig']
oid = 'rad-tiles-lambda'
origins = d['Origins']['Items']
if not any(o['Id'] == oid for o in origins):
    origins.append({"Id": oid, "DomainName": host, "OriginPath": "", "CustomHeaders": {"Quantity": 0},
                    "CustomOriginConfig": {"HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "https-only",
                                           "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
                                           "OriginReadTimeout": 30, "OriginKeepaliveTimeout": 5},
                    "ConnectionAttempts": 3, "ConnectionTimeout": 10, "OriginShield": {"Enabled": False}})
    d['Origins']['Quantity'] = len(origins)
beh = d.setdefault('CacheBehaviors', {"Quantity": 0, "Items": []})
items = beh.setdefault('Items', [])
if not any(b['PathPattern'] == '/tiles/*' for b in items):
    items.insert(0, {"PathPattern": "/tiles/*", "TargetOriginId": oid, "ViewerProtocolPolicy": "redirect-to-https",
                     "AllowedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}},
                     "Compress": False, "CachePolicyId": cp, "OriginRequestPolicyId": orp,
                     "SmoothStreaming": False, "FieldLevelEncryptionId": "",
                     "LambdaFunctionAssociations": {"Quantity": 0}, "FunctionAssociations": {"Quantity": 0}})
    beh['Quantity'] = len(items)
json.dump(d, open('/tmp/dist-new.json', 'w'))
PY
aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
  --distribution-config file:///tmp/dist-new.json --query 'Distribution.DomainName' --output text
echo "tiles: https://<distribution-domain>/tiles/v1/rads/latest/{z}/{x}/{y}.png  (add ?api_key= once 09-tiles-auth.sh is applied)"
