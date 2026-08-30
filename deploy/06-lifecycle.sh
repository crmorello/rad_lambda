#!/bin/bash
# Bucket retention: expire .rad/.flw objects after 1 day (S3 lifecycle
# granularity is days). The manifest window (manifest.cr WINDOW) bounds what
# clients SEE; this bounds what we STORE. Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

aws s3api put-bucket-lifecycle-configuration --bucket "$RAD_BUCKET" \
  --lifecycle-configuration "{
    \"Rules\": [{
      \"ID\": \"expire-rads\",
      \"Filter\": {\"Prefix\": \"${RAD_PREFIX}/\"},
      \"Status\": \"Enabled\",
      \"Expiration\": {\"Days\": 1}
    }]
  }"
echo "lifecycle set: ${RAD_BUCKET}/${RAD_PREFIX}/* expires after 1 day"
