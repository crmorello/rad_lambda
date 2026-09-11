#!/bin/bash
# Add a *.json (all manifests) cache behavior to the LIVE CloudFront distribution and
# invalidate the stale copies. Finds the distribution by the public URL.
#
#   deploy/07-cdn-obs-manifest.sh https://internal-radar.weatherflow.com [DISTRIBUTION_ID]
#   (pass the ID when your identity lacks cloudfront:ListDistributions)
#
# Why: obs/<var>/manifest.json was served under the default long-TTL
# behavior (age > 1000 s while newer frames existed) — the live distribution
# only had "/rads/manifest.json" and "/rads/*.rad". This clones the manifest
# behavior (same short-TTL cache policy) as "*.json": one rule for every
# product's manifest, present and future. .rad frames keep the long TTL.
# Idempotent: skips the update if the pattern is already present.
# Requires: aws CLI with cloudfront:GetDistributionConfig/UpdateDistribution/
# CreateInvalidation on the distribution, jq.
set -euo pipefail
URL="${1:?usage: $0 https://<distribution-domain> [DISTRIBUTION_ID]}"
HOST="${URL#*://}"; HOST="${HOST%%/*}"
PATTERN="*.json"   # every manifest (rads + all obs products, future products too); frames stay on the default
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

WORK=$(mktemp -d)
aws cloudfront get-distribution-config --id "$DIST_ID" --output json > "$WORK/full.json"
ETAG=$(jq -r .ETag "$WORK/full.json")
jq .DistributionConfig "$WORK/full.json" > "$WORK/config.json"

if jq -e --arg p "$PATTERN" '.CacheBehaviors.Items[]? | select(.PathPattern == $p)' "$WORK/config.json" >/dev/null; then
  echo "== behavior for $PATTERN already present — skipping update"
else
  # Template: the existing manifest behavior (short-TTL policy); fall back to
  # the first behavior if the pattern was named differently.
  TEMPLATE=$(jq -c '(.CacheBehaviors.Items[]? | select(.PathPattern | endswith("manifest.json"))) // .CacheBehaviors.Items[0]' "$WORK/config.json")
  [ -n "$TEMPLATE" ] && [ "$TEMPLATE" != "null" ] || { echo "no existing manifest behavior to clone"; exit 1; }
  echo "== cloning behavior $(echo "$TEMPLATE" | jq -r .PathPattern) (policy $(echo "$TEMPLATE" | jq -r .CachePolicyId)) as $PATTERN"
  jq --argjson t "$TEMPLATE" --arg p "$PATTERN" '
      .CacheBehaviors.Items = ([$t | .PathPattern = $p] + (.CacheBehaviors.Items // []))
    | .CacheBehaviors.Quantity = (.CacheBehaviors.Items | length)' "$WORK/config.json" > "$WORK/config.new.json"
  echo "== updating distribution (ETag $ETAG)"
  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
    --distribution-config "file://$WORK/config.new.json" --output json \
    | jq -r '"   status: " + .Distribution.Status'
fi

# Invalidate ONLY the manifests. CloudFront invalidation wildcards must be the
# last character, so "/obs/*/manifest.json" matches nothing and "/obs/*" would
# also evict the (immutable, long-TTL) frames — harmless but pointless. One
# call with the explicit manifest paths instead (the 13 obs variables).
OBS_VARS="temperature dewpoint rh pressure wind_average wind_gust wind_dir solar_radiation precip_rate cloud_cover tempest_pres_obs precip_type conditions_code"
PATHS=""; for v in $OBS_VARS; do PATHS="$PATHS /obs/$v/manifest.json"; done
echo "== invalidating the obs manifests ($(echo $OBS_VARS | wc -w | tr -d ' ') paths)"
# shellcheck disable=SC2086
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths $PATHS --output json \
  | jq -r '"   invalidation " + .Invalidation.Id + " " + .Invalidation.Status'

echo "== verify (repeat after the deploy finishes, ~2-5 min):"
echo "   curl -s --compressed -D - $URL/obs/pressure/manifest.json | grep -iE '^(x-cache|age):|updated_at'"
rm -rf "$WORK"
