#!/bin/bash
# Attach the CORS response-headers policy to EVERY cache behavior of the LIVE
# CloudFront distribution, so browsers on other origins (the web demo on a dev
# host or its own static hosting) can read manifests and frames.
#
#   deploy/10-cdn-cors.sh https://internal-radar.weatherflow.com [DISTRIBUTION_ID]
#   (pass the ID when your identity lacks cloudfront:ListDistributions)
#
# Why: deploy/04-cdn.sh creates "<COMMENT>-cors" and wires it into the
# distribution IT creates, but the live distribution is ops-managed and sends
# no Access-Control-Allow-Origin — the web demo's fetches are blocked. This
# reuses (or creates) the same policy — GET/HEAD, any origin, no credentials —
# and sets ResponseHeadersPolicyId on the default and every path behavior.
# Response-headers policies apply when CloudFront responds, cached or not, so
# no invalidation is needed. Idempotent: skips behaviors already wired.
# Requires: aws CLI with cloudfront:ListResponseHeadersPolicies /
# CreateResponseHeadersPolicy / GetDistributionConfig / UpdateDistribution, jq.
set -euo pipefail
URL="${1:?usage: $0 https://<distribution-domain> [DISTRIBUTION_ID]}"
HOST="${URL#*://}"; HOST="${HOST%%/*}"
POLICY_NAME="${CORS_POLICY_NAME:-tempest-radar-cors}"
export AWS_PAGER=""

if [ -n "${2:-}" ]; then
  DIST_ID="$2"
  echo "== distribution $DIST_ID (given)"
else
  echo "== locating distribution for $HOST"
  DIST_ID=$(aws cloudfront list-distributions --output json \
    | jq -r --arg h "$HOST" '.DistributionList.Items[]
        | select((.Aliases.Items // []) | index($h)) or (.DomainName == $h)) | .Id' | head -1)
  [ -n "$DIST_ID" ] || { echo "no distribution serves $HOST (pass the ID as the 2nd argument)"; exit 1; }
  echo "   $DIST_ID"
fi

echo "== response headers policy $POLICY_NAME"
CORS_ID=$(aws cloudfront list-response-headers-policies --type custom --output json \
  | jq -r --arg n "$POLICY_NAME" '.ResponseHeadersPolicyList.Items[]?
      | select(.ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name == $n) | .ResponseHeadersPolicy.Id' | head -1)
if [ -z "$CORS_ID" ]; then
  CORS_ID=$(aws cloudfront create-response-headers-policy --response-headers-policy-config "{
    \"Name\": \"${POLICY_NAME}\",
    \"Comment\": \"CORS for the Tempest Radar web clients (GET/HEAD, any origin)\",
    \"CorsConfig\": {
      \"AccessControlAllowOrigins\": {\"Quantity\": 1, \"Items\": [\"*\"]},
      \"AccessControlAllowHeaders\": {\"Quantity\": 1, \"Items\": [\"*\"]},
      \"AccessControlAllowMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"]},
      \"AccessControlAllowCredentials\": false,
      \"OriginOverride\": true
    }}" --query 'ResponseHeadersPolicy.Id' --output text)
  echo "   created $CORS_ID"
else
  echo "   exists  $CORS_ID"
fi

WORK=$(mktemp -d)
aws cloudfront get-distribution-config --id "$DIST_ID" --output json > "$WORK/full.json"
ETAG=$(jq -r .ETag "$WORK/full.json")
jq .DistributionConfig "$WORK/full.json" > "$WORK/config.json"

MISSING=$(jq -r --arg id "$CORS_ID" '
  [ (if .DefaultCacheBehavior.ResponseHeadersPolicyId != $id then "default" else empty end),
    (.CacheBehaviors.Items[]? | select(.ResponseHeadersPolicyId != $id) | .PathPattern) ] | length' "$WORK/config.json")
if [ "$MISSING" = "0" ]; then
  echo "== every behavior already uses $CORS_ID — nothing to do"
else
  echo "== wiring $CORS_ID into $MISSING behavior(s):"
  jq -r --arg id "$CORS_ID" '
    (if .DefaultCacheBehavior.ResponseHeadersPolicyId != $id then "   default (*)" else empty end),
    (.CacheBehaviors.Items[]? | select(.ResponseHeadersPolicyId != $id) | "   " + .PathPattern)' "$WORK/config.json"
  jq --arg id "$CORS_ID" '
      .DefaultCacheBehavior.ResponseHeadersPolicyId = $id
    | (.CacheBehaviors.Items[]?) .ResponseHeadersPolicyId = $id' "$WORK/config.json" > "$WORK/config.new.json"
  echo "== updating distribution (ETag $ETAG)"
  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
    --distribution-config "file://$WORK/config.new.json" --output json \
    | jq -r '"   status: " + .Distribution.Status'
fi

echo "== verify (after the deploy finishes, ~2-5 min):"
echo "   curl -s -o /dev/null -D - -H 'Origin: http://localhost:8000' $URL/rads/manifest.json | grep -i access-control"
rm -rf "$WORK"
