# Lambda container image (custom runtime): the Zig binary IS the bootstrap.
#
# GDAL comes from our own pre-packaged minimal base (Dockerfile.gdal, see
# docs/gdal-base-image.md), NOT from ghcr.io/osgeo/gdal:ubuntu-full. That image
# carried ~250 drivers, Python+numpy, HDF5, netCDF, PostgreSQL, Poppler and
# Xerces for a lambda that uses three drivers — 1.85 GB of image, and a cold
# start spent registering all of it. Build the base once, first:
#
#   scripts/build_gdal_base.sh
#
# radcore is its own repo (sibling checkout) — pass it as a named build
# context; it is copied to a path that mirrors the local directory layout,
# so build.zig.zon's relative path dep resolves unchanged:
#
#   docker build \
#     --build-context radcore=$HOME/Developer/Zig/radcore \
#     -t rad-lambda .
#
# The base image is arch-specific (it carries a linux zig toolchain); for
# x86_64 rebuild it with ZIG_ARCH=x86_64 on an amd64 host.
ARG GDAL_BASE=rad-gdal-base:3.11.4

FROM ${GDAL_BASE}-build AS build
# Mirror the dev layout: rad_lambda/zig four levels below the root that also
# holds Zig/radcore (see build.zig.zon).
COPY --from=radcore / /build/Zig/radcore
COPY zig /build/crystal/git/rad_lambda/zig
WORKDIR /build/crystal/git/rad_lambda/zig
# GDAL is under /opt/gdal in the base image. H3 stays on apt (Debian's
# libh3-dev flattens h3api.h into /usr/include, unlike homebrew's h3/ nesting).
RUN zig build -Doptimize=ReleaseFast \
      -Dgdal-include=/opt/gdal/include \
      -Dgdal-lib=/opt/gdal/lib \
      -Dh3-include=/usr/include \
      -Dh3-lib=/usr/lib/$(uname -m)-linux-gnu

FROM ${GDAL_BASE}-runtime
COPY --from=build /build/crystal/git/rad_lambda/zig/zig-out/bin/rad_lambda /var/runtime/bootstrap
# GDAL_DATA / PROJ_DATA / GDAL_DRIVER_PATH come from the runtime base image.
# RAD_OUTPUT (e.g. /vsis3/bucket/rads) is set on the function config.
ENTRYPOINT ["/var/runtime/bootstrap"]
