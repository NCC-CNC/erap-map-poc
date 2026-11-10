#!/usr/bin/env bash
# Layer config loading and validation.
#
# A layer config is a bash file, pipeline/layers/<layer>.env, sourced in a
# subshell per layer. The layer name is the file name without `.env`.
# Variables (see layers/sample.env for a worked example):
#
#   LAYER_INPUT             required. Source dataset path. Relative paths are
#                           resolved against PIPELINE_INPUT_DIR. A `.zip`
#                           (for example a zipped shapefile) is read in place
#                           through GDAL's /vsizip/; name a file inside it as
#                           `data.zip/folder/file.shp`. Paths starting with
#                           /vsi are passed to GDAL unchanged.
#   LAYER_SOURCE_LAYER      optional. Layer inside the source dataset; defaults
#                           to the first layer.
#   LAYER_SOURCE_SRS        optional. Source CRS (for example EPSG:3347) for
#                           inputs without a usable one, such as a shapefile
#                           with no .prj. Passed to ogr2ogr as -s_srs.
#   LAYER_ENCODING          optional. Attribute encoding (for example
#                           ISO-8859-1) for shapefiles without a .cpg. Passed
#                           to ogr2ogr as the open option ENCODING.
#   LAYER_FIELDS            required array. Attributes to keep, as `src` or
#                           `src:dest` to rename. Everything else is dropped.
#                           Use `src:dest` to restore names that shapefile's
#                           10-character limit cut short.
#   LAYER_FEATURE_ID        required. Output attribute holding a stable integer
#                           id; written as the vector tile feature id.
#   LAYER_MIN_ZOOM          required. Minimum tile zoom.
#   LAYER_MAX_ZOOM          required. Maximum tile zoom.
#   LAYER_PROFILE           optional. A named set of tippecanoe flags; see
#                           layer_profile_flags. Empty for none.
#   LAYER_TIPPECANOE_FLAGS  optional array. Extra tippecanoe flags, added after
#                           the profile's.
#   LAYER_MIN_VISIBLE_PX    optional, default 1. Drop guard threshold: a
#                           polygon is required at a zoom once its largest
#                           part covers at least this many screen pixels at
#                           256 px tiles (see lib/guard.sh).

# Default drop guard threshold, in screen pixels at 256 px tiles.
LAYER_MIN_VISIBLE_PX_DEFAULT=1

# layer_name_valid NAME: layer names become file names and URL paths, so keep
# them to lower case letters, digits, `_` and `-`.
layer_name_valid() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# layer_profile_flags PROFILE: print the tippecanoe flags of a named profile,
# one per line. Unknown profiles return 1.
#
#   (empty)   no flags.
#   coverage  contiguous polygon coverages (no overlaps, shared borders):
#             --no-simplification-of-shared-nodes simplifies each shared
#             border once, identically in both neighbours, so no gaps or
#             slivers open along it; --drop-smallest-as-needed drops the
#             physically smallest polygons first when a tile is too big,
#             never large ones for being in a dense area. Tiny polygon
#             reduction (the tippecanoe default) stays on: it only touches
#             polygons below about 1/64 of a screen pixel.
layer_profile_flags() {
  case $1 in
    "") ;;
    coverage)
      printf '%s\n' --no-simplification-of-shared-nodes --drop-smallest-as-needed
      ;;
    *) return 1 ;;
  esac
}

# load_layer_config FILE: source FILE and check the required variables. Call
# only inside the per-layer subshell so one layer's settings cannot leak into
# the next.
load_layer_config() {
  local file=$1
  [[ -r $file ]] || die "layer config not readable: $file"

  # Reset, then set by the config. Some are read only by bin/run.sh.
  LAYER_INPUT=""
  # shellcheck disable=SC2034
  LAYER_SOURCE_LAYER=""
  # shellcheck disable=SC2034
  LAYER_SOURCE_SRS=""
  # shellcheck disable=SC2034
  LAYER_ENCODING=""
  LAYER_FIELDS=()
  LAYER_FEATURE_ID=""
  LAYER_MIN_ZOOM=""
  LAYER_MAX_ZOOM=""
  LAYER_PROFILE=""
  LAYER_TIPPECANOE_FLAGS=()
  LAYER_MIN_VISIBLE_PX=$LAYER_MIN_VISIBLE_PX_DEFAULT

  # shellcheck source=/dev/null
  source "$file"

  [[ -n $LAYER_INPUT ]] || die "LAYER_INPUT is not set in $file"
  ((${#LAYER_FIELDS[@]} > 0)) || die "LAYER_FIELDS is empty in $file"
  [[ -n $LAYER_FEATURE_ID ]] || die "LAYER_FEATURE_ID is not set in $file"
  [[ $LAYER_MIN_ZOOM =~ ^[0-9]+$ ]] || die "LAYER_MIN_ZOOM must be an integer in $file"
  [[ $LAYER_MAX_ZOOM =~ ^[0-9]+$ ]] || die "LAYER_MAX_ZOOM must be an integer in $file"
  ((LAYER_MIN_ZOOM <= LAYER_MAX_ZOOM)) || die "LAYER_MIN_ZOOM > LAYER_MAX_ZOOM in $file"
  [[ $LAYER_MIN_VISIBLE_PX =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "LAYER_MIN_VISIBLE_PX must be a non-negative number in $file"

  local flags
  flags=$(layer_profile_flags "$LAYER_PROFILE") \
    || die "unknown LAYER_PROFILE '$LAYER_PROFILE' in $file"
  # The profile's flags first, so the layer's own flags can add to them.
  local profile_flags=()
  [[ -z $flags ]] || mapfile -t profile_flags <<<"$flags"
  # shellcheck disable=SC2034
  LAYER_TIPPECANOE_FLAGS=("${profile_flags[@]}" "${LAYER_TIPPECANOE_FLAGS[@]}")

  local field dest found=0
  for field in "${LAYER_FIELDS[@]}"; do
    dest=${field#*:}
    [[ $dest == "$LAYER_FEATURE_ID" ]] && found=1
  done
  ((found)) || die "LAYER_FEATURE_ID '$LAYER_FEATURE_ID' is not in LAYER_FIELDS in $file"

  if [[ $LAYER_INPUT != /* ]]; then
    LAYER_INPUT="${PIPELINE_INPUT_DIR}/${LAYER_INPUT}"
  fi
}
