#!/bin/bash
# Output bucket: private, 48h expiry under the rads prefix (server-side
# retention; clients keep 3h). The manifest is rewritten every cycle, so it
# never ages anywhere near expiry — no exemption needed. CloudFront gets read
# access in 04-cdn.sh.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "== bucket"
aws s3api head-bucket --bucket "$RAD_BUCKET" 2>/dev/null || \
  aws s3api create-bucket --bucket "$RAD_BUCKET" --region "$AWS_REGION"

aws s3api put-public-access-block --bucket "$RAD_BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo "== lifecycle: expire ${RAD_PREFIX}/ after 2 days"
aws s3api put-bucket-lifecycle-configuration --bucket "$RAD_BUCKET" \
  --lifecycle-configuration "{
    \"Rules\": [{
      \"ID\": \"expire-rads\",
      \"Status\": \"Enabled\",
      \"Filter\": {\"Prefix\": \"${RAD_PREFIX}/\"},
      \"Expiration\": {\"Days\": 2}
    }]
  }"
echo "bucket: s3://${RAD_BUCKET}/${RAD_PREFIX}/"
