#!/bin/bash
# Roll an image already in ECR (scripts/build_and_push.sh) out to one or all
# of the lambdas that run it. All three run the SAME image; what each one does
# is decided by its own configuration (env vars, trigger), not by the code.
#
# Usage: scripts/deploy.sh <radar|tiles|obs|all> [tag]
#   radar  tempest-radar-output        MRMS grib -> RAD frames (SQS trigger)
#   tiles  tempest-radar-output-tiles  raster tiles behind CloudFront /tiles/*
#   obs    tempest-gcc-output          H3 obs parquet -> obs products (S3 trigger)
#   all    all three, in that order
#   tag    image tag in ECR; defaults to `latest`
#   DRY_RUN=1 prints what would change without updating anything.
#   Overrides: ECR_ACCOUNT, AWS_REGION, ECR_REPO, RADAR_FUNCTION,
#              TILES_FUNCTION, OBS_FUNCTION.
#
# The tag is resolved to its image DIGEST once, up front, and every function is
# pointed at that digest: an `all` deploy gives all three byte-identical code
# even if :latest moves while it runs. Each update also pins arm64 — the image
# is arm64-only, and an x86_64 function fails every invoke with
# Runtime.InvalidEntrypoint (how the obs lambda first broke).
#
# Requires an aws CLI with ecr:BatchGetImage on the repo and
# lambda:UpdateFunctionCode / GetFunction on each target.
set -euo pipefail

ACCOUNT="${ECR_ACCOUNT:-960102610069}"
REGION="${AWS_REGION:-us-east-1}"
REPO="${ECR_REPO:-tempest-radar-output}"
RADAR_FUNCTION="${RADAR_FUNCTION:-tempest-radar-output}"
TILES_FUNCTION="${TILES_FUNCTION:-tempest-radar-output-tiles}"
OBS_FUNCTION="${OBS_FUNCTION:-tempest-gcc-output}"
URI="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO"

usage() {
  sed -n '6,14p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

TARGET="${1:-}"
TAG="${2:-latest}"
case "$TARGET" in
  radar) FUNCTIONS="$RADAR_FUNCTION" ;;
  tiles) FUNCTIONS="$TILES_FUNCTION" ;;
  obs)   FUNCTIONS="$OBS_FUNCTION" ;;
  all)   FUNCTIONS="$RADAR_FUNCTION $TILES_FUNCTION $OBS_FUNCTION" ;;
  *)     usage ;;
esac

echo "== resolve $REPO:$TAG"
# batch-get-image, not describe-images: it needs only ecr:BatchGetImage, which
# any identity that can push or pull already has (ecr:DescribeImages is denied
# for ours). A missing tag is not an error here — it comes back as an empty
# `images` list, i.e. "None".
if ! DIGEST=$(aws ecr batch-get-image --region "$REGION" --repository-name "$REPO" \
     --image-ids imageTag="$TAG" --query 'images[0].imageId.imageDigest' --output text); then
  echo "could not look up $REPO:$TAG (aws error above)" >&2
  exit 1
fi
if [ -z "$DIGEST" ] || [ "$DIGEST" = "None" ]; then
  echo "no image tagged '$TAG' in $URI (push one with scripts/build_and_push.sh)" >&2
  exit 1
fi
IMAGE="$URI@$DIGEST"
echo "   $TAG -> $DIGEST"

FAILED=""
for fn in $FUNCTIONS; do
  current=$(aws lambda get-function --region "$REGION" --function-name "$fn" \
    --query 'Code.ResolvedImageUri' --output text) || current="(unreadable — aws error above)"
  echo "== $fn"
  echo "   now:  $current"
  if [ "$current" = "$IMAGE" ]; then
    echo "   already on this image — skipped"
    continue
  fi
  if [ "${DRY_RUN:-}" = "1" ]; then
    echo "   would deploy: $IMAGE (DRY_RUN)"
    continue
  fi
  if aws lambda update-function-code --region "$REGION" --function-name "$fn" \
       --image-uri "$IMAGE" --architectures arm64 >/dev/null \
     && aws lambda wait function-updated --region "$REGION" --function-name "$fn"; then
    after=$(aws lambda get-function --region "$REGION" --function-name "$fn" \
      --query 'Code.ResolvedImageUri' --output text)
    if [ "$after" = "$IMAGE" ]; then
      echo "   done: $after"
    else
      echo "   UPDATED BUT RUNNING $after, expected $IMAGE" >&2
      FAILED="$FAILED $fn"
    fi
  else
    echo "   FAILED (see the aws error above)" >&2
    FAILED="$FAILED $fn"
  fi
done

if [ -n "$FAILED" ]; then
  echo "deploy failed for:$FAILED" >&2
  exit 1
fi
if [ "${DRY_RUN:-}" = "1" ]; then
  echo "dry run: nothing changed"
else
  echo "deployed $TAG ($DIGEST) to: $FUNCTIONS"
fi
