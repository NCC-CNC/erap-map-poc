#!/usr/bin/env bash
# Layer config loading and validation.
#
# A layer config is a bash file, pipeline/layers/<layer>.env, sourced in a
# subshell per layer. The layer name is the file name without `.env`.
# Variables (see tests/layers/sample.env for a worked vector example and
# layers/forest.env for a raster one):
#
#   LAYER_TYPE              optional, `vector` (default) or `raster`. A raster
#                           layer is a binary (0/1) raster drawn in one colour
#                           from its display config, display only (no
#                           pop-up); see lib/raster.sh. The settings marked
#                           "vector only" below are ignored for it.
#   LAYER_INPUT             required. Source dataset path. Relative paths are
#                           resolved against PIPELINE_INPUT_DIR. A `.zip`
#                           (for example a zipped shapefile) is read in place
#                           through GDAL's /vsizip/; name a file inside it as
#                           `data.zip/folder/file.shp`. Paths starting with
#                           /vsi are passed to GDAL unchanged.
#   LAYER_SOURCE_LAYER      optional, vector only. Layer inside the source
#                           dataset; defaults to the first layer.
#   LAYER_SOURCE_SRS        optional. Source CRS (for example EPSG:3347) for
#                           inputs without a usable one, such as a shapefile
#                           with no .prj. Passed to ogr2ogr as -s_srs (for a
#                           raster, to the prepare step as -a_srs; changing
#                           it prepares the source again).
#   LAYER_ENCODING          optional, vector only. Attribute encoding (for
#                           example ISO-8859-1) for shapefiles without a .cpg.
#                           Passed to ogr2ogr as the open option ENCODING.
#   LAYER_FIELDS            required array, vector only. Attributes to keep,
#                           as `src` or `src:dest` to rename. Everything else
#                           is dropped. Use `src:dest` to restore names that
#                           shapefile's 10-character limit cut short.
#   LAYER_FEATURE_ID        required, vector only. Output attribute holding a
#                           stable integer id; written as the vector tile
#                           feature id.
#   LAYER_CALCULATED        optional array, vector only. Calculated fields,
#                           as `name=expression`: an expression on the
#                           attributes above (LAYER_FIELDS output names) and
#                           other calculated fields, evaluated per feature at
#                           build time and tiled like any attribute. A later
#                           entry for a name replaces an earlier one; an
#                           empty expression removes it. See lib/derive.sh
#                           and ADR 0011 for the expression language.
#   LAYER_RULES             optional, vector only. Action recommendation
#                           rules table (ADR 0011): a name, for
#                           <name>.rules.json next to the layer's .env, or a
#                           path to a .rules.json file (relative to that
#                           folder). Each action's condition is evaluated per
#                           feature and written as attributes (lib/derive.sh).
#   LAYER_MIN_ZOOM          required. Minimum tile zoom.
#   LAYER_MAX_ZOOM          required. Maximum tile zoom. For a raster, also
#                           the resolution it is resampled to (z12 is about
#                           38 m at the equator, 19 to 27 m across Canada).
#                           Changing a raster's zooms reuses its prepared
#                           source (lib/raster.sh, PIPELINE_WORK_DIR).
#   LAYER_NODATA            optional, raster only. Source nodata value, for
#                           a raster that does not declare one (or declares
#                           the wrong one). Used by the prepare step
#                           (lib/raster.sh), which turns nodata into 0;
#                           changing it prepares the source again.
#   LAYER_PROFILE           optional, vector only. A named set of tippecanoe
#                           flags; see layer_profile_flags. Empty for none.
#   LAYER_TIPPECANOE_FLAGS  optional array, vector only. Extra tippecanoe
#                           flags, added after the profile's.
#   LAYER_MIN_VISIBLE_PX    optional, vector only, default 1. Drop guard
#                           threshold: a polygon is required at a zoom once
#                           its largest part covers at least this many screen
#                           pixels at 256 px tiles (see lib/guard.sh).
#   LAYER_GENERALISE_MAX_ZOOM
#                           optional, vector polygons only; empty (default)
#                           for none. Generalise the low zooms, from
#                           LAYER_MIN_ZOOM up to this zoom (below
#                           LAYER_MAX_ZOOM): per zoom, small polygon parts
#                           (islands) are dropped and borders simplified as
#                           a coverage; the zooms above keep full detail.
#                           See lib/generalise.sh.
#   LAYER_GENERALISE_MIN_PART_PX
#                           optional, default 4. With LAYER_GENERALISE_MAX_ZOOM:
#                           at each generalised zoom, drop polygon parts
#                           smaller than this many screen pixels (at 256 px
#                           tiles, as LAYER_MIN_VISIBLE_PX). Each feature
#                           keeps its largest part, so the drop guard holds.
#   LAYER_GENERALISE_SIMPLIFY_PX
#                           optional, default 1. With LAYER_GENERALISE_MAX_ZOOM:
#                           coverage simplification tolerance in screen
#                           pixels at each generalised zoom. Needs a coverage
#                           (no overlaps); 0 skips it, for polygons that
#                           overlap.

# Default drop guard threshold, in screen pixels at 256 px tiles.
LAYER_MIN_VISIBLE_PX_DEFAULT=1

# Default low-zoom generalisation thresholds, in screen pixels at 256 px
# tiles (used only with LAYER_GENERALISE_MAX_ZOOM).
LAYER_GENERALISE_MIN_PART_PX_DEFAULT=4
LAYER_GENERALISE_SIMPLIFY_PX_DEFAULT=1

# Highest max zoom for a raster layer: z14 is about 10 m at the equator,
# already finer than any 30 m source, and each zoom up quadruples the tiles.
RASTER_MAX_ZOOM_LIMIT=14

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
  LAYER_TYPE=vector
  LAYER_INPUT=""
  # shellcheck disable=SC2034
  LAYER_SOURCE_LAYER=""
  # shellcheck disable=SC2034
  LAYER_SOURCE_SRS=""
  # shellcheck disable=SC2034
  LAYER_ENCODING=""
  LAYER_FIELDS=()
  LAYER_FEATURE_ID=""
  LAYER_CALCULATED=()
  # shellcheck disable=SC2034
  LAYER_RULES=""
  LAYER_MIN_ZOOM=""
  LAYER_MAX_ZOOM=""
  LAYER_NODATA=""
  LAYER_PROFILE=""
  LAYER_TIPPECANOE_FLAGS=()
  LAYER_MIN_VISIBLE_PX=$LAYER_MIN_VISIBLE_PX_DEFAULT
  LAYER_GENERALISE_MAX_ZOOM=""
  LAYER_GENERALISE_MIN_PART_PX=$LAYER_GENERALISE_MIN_PART_PX_DEFAULT
  LAYER_GENERALISE_SIMPLIFY_PX=$LAYER_GENERALISE_SIMPLIFY_PX_DEFAULT

  # shellcheck source=/dev/null
  source "$file"

  [[ -n $LAYER_INPUT ]] || die "LAYER_INPUT is not set in $file"
  [[ $LAYER_MIN_ZOOM =~ ^[0-9]+$ ]] || die "LAYER_MIN_ZOOM must be an integer in $file"
  [[ $LAYER_MAX_ZOOM =~ ^[0-9]+$ ]] || die "LAYER_MAX_ZOOM must be an integer in $file"
  ((LAYER_MIN_ZOOM <= LAYER_MAX_ZOOM)) || die "LAYER_MIN_ZOOM > LAYER_MAX_ZOOM in $file"

  if [[ $LAYER_INPUT != /* ]]; then
    LAYER_INPUT="${PIPELINE_INPUT_DIR}/${LAYER_INPUT}"
  fi

  case $LAYER_TYPE in
    vector) _check_vector_config "$file" ;;
    raster) _check_raster_config "$file" ;;
    *) die "LAYER_TYPE must be vector or raster in $file" ;;
  esac
}

# _check_raster_config FILE: the raster-only settings.
_check_raster_config() {
  local file=$1
  ((LAYER_MAX_ZOOM <= RASTER_MAX_ZOOM_LIMIT)) \
    || die "LAYER_MAX_ZOOM must be at most ${RASTER_MAX_ZOOM_LIMIT} for a raster in $file"
  [[ -z $LAYER_NODATA || $LAYER_NODATA =~ ^(-?[0-9]+([.][0-9]+)?|nan|NaN)$ ]] \
    || die "LAYER_NODATA must be a number or nan in $file"
}

# _check_vector_config FILE: the vector-only settings.
_check_vector_config() {
  local file=$1
  ((${#LAYER_FIELDS[@]} > 0)) || die "LAYER_FIELDS is empty in $file"
  [[ -n $LAYER_FEATURE_ID ]] || die "LAYER_FEATURE_ID is not set in $file"
  [[ $LAYER_MIN_VISIBLE_PX =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "LAYER_MIN_VISIBLE_PX must be a non-negative number in $file"
  if [[ -n $LAYER_GENERALISE_MAX_ZOOM ]]; then
    [[ $LAYER_GENERALISE_MAX_ZOOM =~ ^[0-9]+$ ]] \
      || die "LAYER_GENERALISE_MAX_ZOOM must be an integer in $file"
    ((LAYER_GENERALISE_MAX_ZOOM >= LAYER_MIN_ZOOM && LAYER_GENERALISE_MAX_ZOOM < LAYER_MAX_ZOOM)) \
      || die "LAYER_GENERALISE_MAX_ZOOM must be from LAYER_MIN_ZOOM to below LAYER_MAX_ZOOM in $file"
  fi
  [[ $LAYER_GENERALISE_MIN_PART_PX =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "LAYER_GENERALISE_MIN_PART_PX must be a non-negative number in $file"
  [[ $LAYER_GENERALISE_SIMPLIFY_PX =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "LAYER_GENERALISE_SIMPLIFY_PX must be a non-negative number in $file"

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

  # The expressions are checked against the attributes at build time
  # (lib/derive.sh); here only the shape of each entry.
  local entry
  for entry in "${LAYER_CALCULATED[@]}"; do
    [[ $entry =~ ^[a-z][a-z0-9_]*= ]] \
      || die "LAYER_CALCULATED entry '$entry' must be name=expression (name in lower case letters, digits and _) in $file"
  done
}
