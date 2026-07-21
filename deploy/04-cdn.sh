#!/bin/bash
# CloudFront in front of the bucket (OAC): immutable long-TTL for .rad
# (objects carry Cache-Control? no — TTL set here; bodies are gzipped at rest
# with Content-Encoding metadata, served as-is), short-TTL revalidation for
# manifest.json, CORS for the web demo. Runs once; re-runs skip.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

ORIGIN_DOMAIN="${RAD_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
COMMENT="tempest-radar-rads"

EXISTING=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${COMMENT}'].Id | [0]" --output text 2>/dev/null || echo None)
if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  DOMAIN=$(aws cloudfront get-distribution --id "$EXISTING" --query 'Distribution.DomainName' --output text)
  echo "distribution exists: $EXISTING ($DOMAIN)"; exit 0
fi

echo "== OAC"
OAC_ID=$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${COMMENT}'].Id | [0]" --output text 2>/dev/null || echo None)
if [ "$OAC_ID" = "None" ] || [ -z "$OAC_ID" ]; then
  OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=${COMMENT},OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4" \
    --query 'OriginAccessControl.Id' --output text)
fi

echo "== response headers policy (CORS for the web demo)"
CORS_ID=$(aws cloudfront list-response-headers-policies --type custom \
  --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='${COMMENT}-cors'].ResponseHeadersPolicy.Id | [0]" \
  --output text 2>/dev/null || echo None)
if [ "$CORS_ID" = "None" ] || [ -z "$CORS_ID" ]; then
  CORS_ID=$(aws cloudfront create-response-headers-policy --response-headers-policy-config "{
    \"Name\": \"${COMMENT}-cors\",
    \"CorsConfig\": {
      \"AccessControlAllowOrigins\": {\"Quantity\": 1, \"Items\": [\"*\"]},
      \"AccessControlAllowHeaders\": {\"Quantity\": 1, \"Items\": [\"*\"]},
      \"AccessControlAllowMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"]},
      \"AccessControlAllowCredentials\": false,
      \"OriginOverride\": true
    }}" --query 'ResponseHeadersPolicy.Id' --output text)
fi

echo "== distribution"
# Managed cache policies: CachingOptimized (long TTL, honors origin) for .rad;
# UseOriginCacheControlHeaders-QueryStrings unsuitable — manifest gets a short
# custom TTL policy instead.
CACHING_OPTIMIZED="658327ea-f89d-4fab-a63d-7e88639e58f6"
MANIFEST_POLICY_ID=$(aws cloudfront list-cache-policies --type custom \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='${COMMENT}-manifest'].CachePolicy.Id | [0]" \
  --output text 2>/dev/null || echo None)
if [ "$MANIFEST_POLICY_ID" = "None" ] || [ -z "$MANIFEST_POLICY_ID" ]; then
  MANIFEST_POLICY_ID=$(aws cloudfront create-cache-policy --cache-policy-config "{
    \"Name\": \"${COMMENT}-manifest\",
    \"DefaultTTL\": 15, \"MaxTTL\": 60, \"MinTTL\": 0,
    \"ParametersInCacheKeyAndForwardedToOrigin\": {
      \"EnableAcceptEncodingGzip\": true, \"EnableAcceptEncodingBrotli\": false,
      \"HeadersConfig\": {\"HeaderBehavior\": \"none\"},
      \"CookiesConfig\": {\"CookieBehavior\": \"none\"},
      \"QueryStringsConfig\": {\"QueryStringBehavior\": \"none\"}
    }}" --query 'CachePolicy.Id' --output text)
fi

DIST=$(aws cloudfront create-distribution --distribution-config "{
  \"CallerReference\": \"${COMMENT}-$(date +%s)\",
  \"Comment\": \"${COMMENT}\",
  \"Enabled\": true,
  \"DefaultRootObject\": \"\",
  \"Origins\": {\"Quantity\": 1, \"Items\": [{
    \"Id\": \"s3\", \"DomainName\": \"${ORIGIN_DOMAIN}\",
    \"OriginAccessControlId\": \"${OAC_ID}\",
    \"S3OriginConfig\": {\"OriginAccessIdentity\": \"\"}
  }]},
  \"DefaultCacheBehavior\": {
    \"TargetOriginId\": \"s3\", \"ViewerProtocolPolicy\": \"redirect-to-https\",
    \"CachePolicyId\": \"${CACHING_OPTIMIZED}\",
    \"ResponseHeadersPolicyId\": \"${CORS_ID}\",
    \"AllowedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"],
      \"CachedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"]}},
    \"Compress\": false
  },
  \"CacheBehaviors\": {\"Quantity\": 1, \"Items\": [{
    \"PathPattern\": \"*/manifest.json\",
    \"TargetOriginId\": \"s3\", \"ViewerProtocolPolicy\": \"redirect-to-https\",
    \"CachePolicyId\": \"${MANIFEST_POLICY_ID}\",
    \"ResponseHeadersPolicyId\": \"${CORS_ID}\",
    \"AllowedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"],
      \"CachedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\", \"HEAD\"]}},
    \"Compress\": false
  }]}
}" --query 'Distribution.[Id,DomainName]' --output text)
DIST_ID=$(echo "$DIST" | cut -f1)
DOMAIN=$(echo "$DIST" | cut -f2)

echo "== bucket policy (CloudFront read via OAC)"
aws s3api put-bucket-policy --bucket "$RAD_BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
    \"Action\": \"s3:GetObject\",
    \"Resource\": \"arn:aws:s3:::${RAD_BUCKET}/*\",
    \"Condition\": {\"StringEquals\": {
      \"AWS:SourceArn\": \"arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}\"
    }}
  }]
}"
echo "distribution: ${DIST_ID}"
echo "URL:          https://${DOMAIN}/${RAD_PREFIX}/manifest.json"
