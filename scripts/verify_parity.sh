#!/bin/bash
# Byte-parity gate for a rebuilt GDAL: does the new image produce EXACTLY the
# same RAD as the old ghcr.io/osgeo/gdal:ubuntu-full-3.11.4 build?
#
# This is the check test/e2e_local.sh cannot make. That test cmp's lambda-mode
# against CLI-mode of the SAME image, so it proves internal consistency but
# would not notice the whole image drifting. The RADs already in the bucket
# were minted by the OSGeo image's warp kernel, and the format contract is
# byte-identical output (README "parity gate"), so a rebuilt GDAL/PROJ must
# reproduce them exactly.
#
# Usage: scripts/verify_parity.sh [new-image] [reference-image]
#   defaults: rad-lambda:local  ghcr.io/osgeo/gdal-based rad-lambda:baseline
#   GRIB_DIR  dir of MRMS *.grib2.gz fixtures
#   REF_IMAGE image known to produce correct RADs (the old build)
set -euo pipefail
cd "$(dirname "$0")/.."

NEW_IMAGE="${1:-rad-lambda:local}"
REF_IMAGE="${2:-${REF_IMAGE:-rad-lambda:baseline}}"
GRIB_DIR="${GRIB_DIR:-/Users/cmorello/Developer/crystal/git/data_manager/.claude/worktrees/dataset-refactor/temp/raw_gribs/conus}"

WORK=$(mktemp -d /tmp/radlambda-parity.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$GRIB_DIR" ] || fail "GRIB_DIR not found: $GRIB_DIR"

# Every on-grid fixture, not just one — a single frame can hide a resampling
# difference that only shows up at another extent.
# No mapfile: macOS ships bash 3.2.
GRIBS=()
while IFS= read -r g; do GRIBS+=("$g"); done < <(ls "$GRIB_DIR"/*.grib2.gz 2>/dev/null \
  | grep "[0-9]\{8\}-[0-9]\{2\}[0-9]000\.grib2\.gz" | head -4)
[ "${#GRIBS[@]}" -gt 0 ] || fail "no on-grid gribs in $GRIB_DIR"

run_cli() { # image, outdir, grib
  docker run --rm \
    -v "$GRIB_DIR":/data:ro -v "$2":/out \
    --entrypoint /var/runtime/bootstrap "$1" \
    "/data/$(basename "$3")" /out >/dev/null 2>&1
}

echo "reference: $REF_IMAGE"
echo "candidate: $NEW_IMAGE"
echo

rc=0
i=0
for g in "${GRIBS[@]}"; do
  name=$(basename "$g")
  i=$((i + 1))
  # A UNIQUE dir per frame, never deleted and recreated at the same path:
  # on macOS a recreated directory can leave the docker bind mount attached to
  # the stale inode, which shows up as a spurious "image failed" on frame 2+.
  # The EXIT trap removes $WORK wholesale, so nothing needs cleaning here.
  refd="$WORK/ref-$i"; newd="$WORK/new-$i"
  mkdir -p "$refd" "$newd"
  run_cli "$REF_IMAGE" "$refd" "$g" || fail "reference image failed on $name"
  run_cli "$NEW_IMAGE" "$newd" "$g" || fail "candidate image failed on $name"

  for f in "$refd"/*.rad; do
    b=$(basename "$f")
    if [ ! -f "$newd/$b" ]; then
      echo "  MISSING  $b"; rc=1; continue
    fi
    if cmp -s "$f" "$newd/$b"; then
      echo "  ok       $b  ($(wc -c < "$f") bytes)"
    else
      echo "  DIFFER   $b"
      echo "           ref $(shasum -a 256 < "$f" | cut -c1-16)  new $(shasum -a 256 < "$newd/$b" | cut -c1-16)"
      cmp "$f" "$newd/$b" | head -3 | sed 's/^/           /'
      rc=1
    fi
  done
done

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: byte-identical RAD output across ${#GRIBS[@]} frame(s)"
else
  echo "FAIL: RAD output differs — the rebuilt GDAL/PROJ changed the warp result"
fi
exit "$rc"
