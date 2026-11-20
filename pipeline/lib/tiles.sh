#!/usr/bin/env bash
# Build a layer's .pmtiles with tippecanoe.
#
# tippecanoe writes the new archive in the layer's scratch dir, on the
# container's own disk, where it is verified and then checked (the drop
# guard, lib/guard.sh). Written to and read from a Docker Desktop bind
# mount (data/tiles/), the same steps take several times as long (#141).
# Only then is it copied to a hidden temp file in the output dir (same
# filesystem, so the final `mv` is an atomic rename). A failed build or
# check leaves any existing <layer>.pmtiles untouched, so the web app never
# serves a half-written or failed archive.

# build_tiles LAYER INPUT OUT_DIR MIN_ZOOM MAX_ZOOM FEATURE_ID TMP_DIR CHECK [FLAG...]
# CHECK, if not empty, is a command run as `CHECK ARCHIVE` on the new archive;
# it fails the build by exiting non-zero (for example through `die`).
build_tiles() {
  local layer=$1 input=$2 out_dir=$3 minzoom=$4 maxzoom=$5 feature_id=$6 tmp_dir=$7 check=$8
  shift 8

  local final="${out_dir}/${layer}.pmtiles"
  # Must end in .pmtiles: tippecanoe picks the output format by extension.
  local built="${tmp_dir}/${layer}.pmtiles"
  _BUILD_TILES_TMP="${out_dir}/.${layer}.$$.tmp.pmtiles"
  trap 'rm -f "${_BUILD_TILES_TMP:-}"' EXIT
  rm -f "$built" "$_BUILD_TILES_TMP"

  # --read-parallel: the input is line-delimited GeoJSONSeq, so tippecanoe
  # can split it between threads. It only pays off for large inputs but
  # costs nothing for small ones.
  log_info "building tiles z${minzoom}-z${maxzoom}${*:+ with $*}"
  tippecanoe --quiet \
    --output="$built" \
    --layer="$layer" --name="$layer" \
    --minimum-zoom="$minzoom" --maximum-zoom="$maxzoom" \
    --use-attribute-for-id="$feature_id" \
    --temporary-directory="$tmp_dir" \
    --read-parallel \
    "$@" "$input" \
    || die "tippecanoe failed"

  pmtiles verify "$built" >/dev/null 2>&1 \
    || die "pmtiles verify failed for the new archive"

  if [[ -n $check ]]; then
    "$check" "$built"
  fi

  cp "$built" "$_BUILD_TILES_TMP" || die "cannot write $final"
  mv -f "$_BUILD_TILES_TMP" "$final"
  _BUILD_TILES_TMP=""
  rm -f "$built"
  log_info "wrote $final"
}
