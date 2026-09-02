# Lambda container image (custom runtime): the Zig binary IS the bootstrap.
#
# radcore lives in the raydare repo — pass it as a named build context; it is
# copied to a path that mirrors the local directory layout, so
# build.zig.zon's relative path dep resolves unchanged:
#
#   docker build \
#     --build-context radcore=$HOME/Developer/Swift/Playgrounds/raydare/radcore \
#     -t rad-lambda .
#
# Base: OSGeo's GDAL image, not Ubuntu's libgdal — the obs ingest reads
# parquet through OGR and Ubuntu 24.04's libgdal 3.8 is built WITHOUT the
# Parquet/Arrow driver (verified 2026-09-01). Both stages use the same image
# so libgdal sonames match. H3 (obs hex rasterization) comes from apt.
# For arm64 lambdas set ZIG_ARCH=aarch64 and build on/for arm64.
ARG GDAL_IMAGE=ghcr.io/osgeo/gdal:ubuntu-full-3.11.4

# The image ships Apache's Arrow apt source whose signing key is not in the
# image (apt-get update fails: NO_PUBKEY); Arrow itself is already installed
# and we add nothing from that repo, so drop the source before apt runs.
FROM ${GDAL_IMAGE} AS build
RUN rm -f /etc/apt/sources.list.d/apache-arrow.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
      libh3-dev curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.16.0
ARG ZIG_ARCH=x86_64
RUN curl -fsSL https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz \
      | tar -xJ -C /opt && ln -s /opt/zig-*/zig /usr/local/bin/zig

# Mirror the dev layout: rad_lambda/zig four levels below the root that also
# holds Swift/Playgrounds/raydare (see build.zig.zon).
COPY --from=radcore / /build/Swift/Playgrounds/raydare/radcore
COPY zig /build/crystal/git/rad_lambda/zig
WORKDIR /build/crystal/git/rad_lambda/zig
# gdal-config --cflags is -I/usr/include in this image; libs are multiarch.
RUN zig build -Doptimize=ReleaseFast \
      -Dgdal-include=/usr/include \
      -Dgdal-lib=/usr/lib/$(uname -m)-linux-gnu \
      -Dh3-include=/usr/include \
      -Dh3-lib=/usr/lib/$(uname -m)-linux-gnu

FROM ${GDAL_IMAGE}
RUN rm -f /etc/apt/sources.list.d/apache-arrow.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
      libh3-1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/crystal/git/rad_lambda/zig/zig-out/bin/rad_lambda /var/runtime/bootstrap
# RAD_OUTPUT (e.g. /vsis3/bucket/rads) is set on the function config
ENTRYPOINT ["/var/runtime/bootstrap"]
