#!/bin/bash
# Build the pre-packaged minimal GDAL base image (both targets).
#
# Run this RARELY — only when a version in Dockerfile.gdal changes. The app
# build (scripts/build_and_push.sh) then just compiles the Zig binary against
# it, which takes seconds instead of recompiling GDAL.
#
# Usage: scripts/build_gdal_base.sh [--push]
#   --push  also tag and push to ECR (needs the repo to exist:
#           aws ecr create-repository --repository-name tempest-gdal-base)
#   Overrides: GDAL_VERSION, ZIG_ARCH, PLATFORM, ECR_ACCOUNT, AWS_REGION,
#              GDAL_BASE_REPO, LOCAL_BASE.
#
# Requires: docker. Pushing additionally needs aws CLI with ECR push rights.
set -euo pipefail
cd "$(dirname "$0")/.."

GDAL_VERSION="${GDAL_VERSION:-3.11.4}"
ZIG_ARCH="${ZIG_ARCH:-aarch64}"
PLATFORM="${PLATFORM:-linux/arm64}"
LOCAL_BASE="${LOCAL_BASE:-rad-gdal-base:$GDAL_VERSION}"

ACCOUNT="${ECR_ACCOUNT:-960102610069}"
REGION="${AWS_REGION:-us-east-1}"
GDAL_BASE_REPO="${GDAL_BASE_REPO:-tempest-gdal-base}"

for target in build runtime; do
  echo "== docker build --target $target ($PLATFORM, GDAL $GDAL_VERSION)"
  docker build --platform "$PLATFORM" \
    -f Dockerfile.gdal --target "$target" \
    --build-arg "GDAL_VERSION=$GDAL_VERSION" \
    --build-arg "ZIG_ARCH=$ZIG_ARCH" \
    -t "$LOCAL_BASE-$target" .
done

echo
echo "built:"
docker image ls "${LOCAL_BASE%%:*}" --format '  {{.Repository}}:{{.Tag}}  {{.Size}}'

# Quick smoke test: the driver set is the whole point of this image, so assert
# it here rather than discovering a missing GRIB driver during an e2e run.
echo
echo "== driver check"
docker run --rm --entrypoint sh "$LOCAL_BASE-build" -c '
  export GDAL_DRIVER_PATH=/opt/gdal/lib/gdalplugins
  export GDAL_DATA=/opt/gdal/share/gdal PROJ_DATA=/opt/gdal/share/proj
  export LD_LIBRARY_PATH=/opt/gdal/lib
  /opt/gdal/bin/gdalinfo --version
  echo "raster drivers: $(/opt/gdal/bin/gdalinfo  --formats | tail -n +2 | wc -l)"
  echo "vector drivers: $(/opt/gdal/bin/ogrinfo   --formats | tail -n +2 | wc -l)"
  /opt/gdal/bin/gdalinfo --formats | grep -iE "GRIB|MEM|VRT|JP2"
  /opt/gdal/bin/ogrinfo  --formats | grep -i parquet
  /opt/gdal/bin/projinfo EPSG:3857 >/dev/null && echo "proj.db: EPSG:3857 resolves"
'

if [ "${1:-}" != "--push" ]; then
  echo
  echo "local only. re-run with --push to publish to ECR."
  exit 0
fi

URI="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$GDAL_BASE_REPO"
echo "== ecr login"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

for target in build runtime; do
  docker tag "$LOCAL_BASE-$target" "$URI:$GDAL_VERSION-$ZIG_ARCH-$target"
  docker push "$URI:$GDAL_VERSION-$ZIG_ARCH-$target"
done
echo "pushed: $URI:$GDAL_VERSION-$ZIG_ARCH-{build,runtime}"
echo "point Dockerfile's GDAL_BASE at $URI:$GDAL_VERSION-$ZIG_ARCH"
