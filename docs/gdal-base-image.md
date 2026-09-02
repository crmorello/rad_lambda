# Minimal GDAL base image

## Why

`Dockerfile` used to build on `ghcr.io/osgeo/gdal:ubuntu-full-3.11.4` for both
stages. That image carries ~250 GDAL drivers, Python bindings + numpy, HDF5,
netCDF, PostgreSQL, Poppler, Xerces, Qt5 and the rest of the "full" dependency
set. Cost: **1.85 GB** built locally (806 MB as the pulled ECR image), and a
cold start spent registering all ~250 drivers, `dlopen`-ing the image's plugin
set, and letting `ld.so` map and relocate ~120 shared objects — nearly none of
which this lambda touches.

It was pinned for exactly one reason: the obs ingest reads parquet through OGR,
and Ubuntu's `libgdal` 3.8 ships without the Parquet/Arrow driver.

## What the code actually needs

Verified against source *and* `nm -u` on the built binary.

| Need | Detail |
|---|---|
| Raster drivers | **GRIB** (`main.zig:86-88`) + **MEM** (`gdal.zig:76`, `-of MEM`) |
| Vector drivers | **Parquet** (`obs.zig:143`), `--obs` path only |
| gdal_utils | `GDALWarp`, `GDALWarpAppOptionsNew/Free` only (`gdal.zig:78-84`) |
| VSI | `/vsigzip/` (zlib), `/vsis3/` (curl — non-negotiable), `VSIOpenDir` |
| PROJ | One use: `-t_srs EPSG:3857` inside the warp. `proj.db` only — both sides are WGS84, **no datum grids** |
| GEOS | **Zero** calls. No `OGR_G_*`; `obs.zig:293` rasterizes H3 hexagons itself |
| OSR | **Zero** calls |
| Output | All raw bytes via `VSIFWriteL` — **no output driver at all** |

## Result (measured)

| | Before | After |
|---|---|---|
| App image, built locally | 1.85 GB | **221 MB** |
| Pulled ECR image | 806 MB | (expect ~80 MB) |
| Raster + vector drivers | ~250 | **12** |
| GDAL build time | n/a (prebuilt) | **~60 s** |
| RAD output | reference | **byte-identical** |

Layer breakdown of the 221 MB:

```
101 MB  debian:trixie-slim
 51 MB  arrow + parquet runtime (deferred; not paged in on the radar path)
 27 MB  curl, sqlite3, openjpeg, h3, zlib, ca-certificates
 20 MB  /opt/gdal/lib   (libgdal 14.7, libproj 3.8, ogr_Parquet.so 0.8)
 12 MB  /opt/gdal/share (proj.db 8.9, gdal data 1.7)
 10 MB  the zig bootstrap (unstripped — keeps panic traces symbolized)
```

## Version pinning is deliberate

GDAL **3.11.4** and PROJ **9.6.1** match the OSGeo image exactly. The RADs
already in the bucket were minted by that warp kernel and the format contract
is byte-identical output (README "parity gate"), so the versions are not free
to float. Debian's `libproj25` is 9.6.0; that is one reason PROJ is built from
source rather than apt-installed.

`scripts/verify_parity.sh` is the gate: it runs the candidate and a reference
image in CLI mode over several real MRMS gribs and `cmp`s the `.rad` output.
This is the check `test/e2e_local.sh` cannot make — that test cmps lambda-mode
against CLI-mode of the *same* image, proving internal consistency but not that
the image as a whole hasn't drifted.

## Things that were not obvious

Each of these was found by measuring, and each would have been a silent bug or
silent bloat.

**MRMS GRIB2 uses PNG packing.** Parsing section 5 of a real fixture gives
`DRS_template=41`, so internal libpng is *required*, not optional. Without it
the driver builds fine and fails to decode at runtime.

**`libparquet` drags in Qt5 and ICU — ~56 MB.** Chain:
`libparquet2500 -> libthrift-0.19.0t64 -> libqt5{core,dbus,network} -> libicu76`
plus glib and shared-mime-info. Debian ships `libthrift`, `libthriftnb`,
`libthriftz` **and** `libthriftqt5` in one package; `objdump -p` shows only the
67 KB `libthriftqt5-*.so` links Qt, while `libthrift-*.so` (the one Parquet
needs) links just ssl/crypto/stdc++. So apt resolves the real closure, then the
Qt half is purged and an `ldd` guard in the runtime stage fails the build if
that broke anything.

**`GDAL_USE_EXTERNAL_LIBS=OFF` is the lever that matters.** It flips the default
for all ~40 `GDAL_USE_<dep>` options at once, so HDF5/netCDF/Poppler/Xerces/
PostgreSQL stay out without being named. Only curl, openjpeg, zlib and arrow
are switched back on.

**Layer discipline is load-bearing.** Deleting files in a later `RUN` only
writes a whiteout — the bytes stay in the lower layer and ECR still pulls them.
The first working version measured 205 MB inside the container but was a 268 MB
image for exactly this reason. Every install/strip-down pair now happens in one
`RUN`, and `/opt/gdal` is pruned in the build stage *before* it is `COPY`d.

**The arrow apt-source deb `Depends: gnupg`**, which pulls pinentry-qt -> Qt5
-> ICU. The deb is two files (a `.sources` and a keyring), so `dpkg -x` unpacks
it without dependency resolution; apt verifies the repo with `gpgv` alone.

**`GDAL_USE_ARROWDATASET` linked `libarrow_dataset` for nothing.**
`obs.zig:153` opens a single file path, never a `PARQUET:`-prefixed dataset
scan. The `ldd` guard caught the dangling dependency.

**`proj-data` is a hard dep of Debian's `libproj25`** — 24 MB of datum grids
(`egm96_15.gtx`, `CHENYX06*.gsb`, …) unreachable from an analytical
WGS84 -> 3857 transform, plus `libcurl3t64-gnutls` and `libtiff6`. Building
PROJ from source with `ENABLE_CURL=OFF -DENABLE_TIFF=OFF -DBUILD_PROJSYNC=OFF`
drops all of it.

## Parquet ships as a deferred plugin

Built with `OGR_ENABLE_DRIVER_PARQUET_PLUGIN=ON`, so GDAL 3.9+ RFC 96 compiles
a stub proxy driver into `libgdal` and only `dlopen`s `ogr_Parquet.so` when a
file actually matches it. Consequences, all verified:

- A GRIB-only run with `CPL_DEBUG=ON` logs **no** plugin load — the radar path
  never pays for Arrow.
- `Parquet` still appears in `ogrinfo --formats`, so `hasParquetDriver()`
  (`obs.zig:141`) reports it available.
- `GDAL_DRIVER_PATH` is baked into the runtime image, so the obs CLI and the
  future `.parquet` hook in `handleEvent` need no env wiring.

## Env baked into the runtime image

`GDAL_DATA` and `PROJ_DATA` are **load-bearing and new**: the code never calls
`CPLSetConfigOption` (there is none anywhere in `gdal.zig`), so until now it
coasted on the OSGeo image's baked-in defaults. Get them wrong and `EPSG:3857`
at `gdal.zig:76` fails at runtime. Also set: `PROJ_NETWORK=OFF`,
`GDAL_DRIVER_PATH`, `LD_LIBRARY_PATH`, `GDAL_PAM_ENABLED=NO` (stops a wasted
`.aux.xml` probe per `/vsis3` open), `CPL_TMPDIR=/tmp`, `GDAL_CACHEMAX=256`.

## Verification

```
scripts/build_gdal_base.sh          # builds both targets + driver smoke test
scripts/build_and_push.sh           # SKIP_DEPLOY=1 to build without deploying
scripts/verify_parity.sh            # byte-identical RAD vs reference image
test/e2e_local.sh rad-lambda:local  # MinIO + RIE, full runtime loop
```

Status: all four pass. Parity is byte-identical over 4 CONUS frames; e2e covers
process + off-grid skip + gzip metadata + manifest + internal byte parity; the
obs/parquet path produces 14 products plus a wind `.flw` sidecar.

Cold start still needs measuring on real infrastructure — Lambda lazily loads
image blocks, so the improvement is not linear in image size. Capture a
baseline `Init Duration` **before** deploying:

```
aws logs filter-log-events --log-group-name /aws/lambda/tempest-radar-output \
  --filter-pattern REPORT
```

## If more needs to come off

- **Strip the bootstrap** (−8 MB): costs symbolized panic traces.
- **Drop Parquet from this image** (−51 MB): obs would need its own tag off the
  same base.
- **Distroless runtime** (−~65 MB): removes apt/dpkg/perl/coreutils and the
  shell, so no in-container debugging.
- **Drop JP2OpenJPEG** (−~1 MB): only insurance for GRIB DRS template 40, which
  SeamlessHSR does not use.
