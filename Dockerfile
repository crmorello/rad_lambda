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
# Keep both stages on the same distro release so libgdal sonames match.
# For arm64 lambdas set ZIG_ARCH=aarch64 and build on/for arm64.

FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgdal-dev curl xz-utils ca-certificates \
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
RUN zig build -Doptimize=ReleaseFast \
      -Dgdal-include=/usr/include/gdal \
      -Dgdal-lib=/usr/lib/$(uname -m)-linux-gnu

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgdal-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/crystal/git/rad_lambda/zig/zig-out/bin/rad_lambda /var/runtime/bootstrap
# RAD_OUTPUT (e.g. /vsis3/bucket/rads) is set on the function config
ENTRYPOINT ["/var/runtime/bootstrap"]
