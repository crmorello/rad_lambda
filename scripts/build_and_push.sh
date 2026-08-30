#!/bin/bash
# Build the arm64 lambda container image and push it to ECR.
#
# Usage: scripts/build_and_push.sh [tag]
#   tag defaults to a UTC timestamp (vYYYYMMDD-HHMMSS); :latest is also pushed.
#   SKIP_TESTS=1 to skip the zig test gate.
#   Overrides: ECR_ACCOUNT, AWS_REGION, ECR_REPO, RADCORE_DIR.
#
# Requires: docker, zig, aws CLI with push permissions on the repo.
# Full local validation (MinIO + RIE) is separate: test/e2e_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT="${ECR_ACCOUNT:-960102610069}"
REGION="${AWS_REGION:-us-east-1}"
REPO="${ECR_REPO:-tempest-radar-output}"
RADCORE="${RADCORE_DIR:-$HOME/Developer/Swift/Playgrounds/raydare/radcore}"
TAG="${1:-v$(date -u +%Y%m%d-%H%M%S)}"
URI="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO"

if [ "${SKIP_TESTS:-}" != "1" ]; then
  echo "== zig build test"
  (cd zig && zig build test)
fi

echo "== docker build (arm64)"
docker build \
  --build-context radcore="$RADCORE" \
  --build-arg ZIG_ARCH=aarch64 \
  -t rad-lambda:local .

echo "== ecr login"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

echo "== push $URI:$TAG"
docker tag rad-lambda:local "$URI:$TAG"
docker tag rad-lambda:local "$URI:latest"
docker push "$URI:$TAG"
docker push "$URI:latest"

echo "pushed: $URI:$TAG (and :latest) — function must be created/updated as arm64"
