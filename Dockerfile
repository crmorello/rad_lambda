# Lambda container image (custom runtime): the binary IS the bootstrap.
# NOTE: shard.yml pulls lib_gdal from github — push the GDALWarp/VSIFWriteL
# binding changes before building this image.
# Keep both stages on the same distro release so libgdal sonames match.

FROM crystallang/crystal:1.20.2 AS build
RUN apt-get update && apt-get install -y --no-install-recommends libgdal-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY shard.yml ./
RUN shards install --production
COPY src ./src
RUN shards build --release --production

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgdal-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/bin/rad_lambda /var/runtime/bootstrap
# RAD_OUTPUT (e.g. /vsis3/bucket/prefix) is set on the function config
ENTRYPOINT ["/var/runtime/bootstrap"]
