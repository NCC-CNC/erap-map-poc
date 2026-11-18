#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR/..
# Raster layer tests (the raster profile, lib/raster.sh, ADR 0008 and 0010)
# on synthetic binary GeoTIFFs made at test time by fixtures/make_raster.sh
# (no committed .tif). Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  MAKE="${PIPELINE_ROOT}/tests/fixtures/make_raster.sh"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_WORK_DIR="${BATS_TEST_TMPDIR}/work"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  COG="${PIPELINE_OUTPUT_DIR}/cover.cog.tif"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# raster_layer NAME KIND [EXPR...]: make a KIND raster (make_raster.sh) and
# a raster layer file for it (fixtures/raster.yaml, z3 to z8), changed by
# any yq EXPRs.
raster_layer() {
  local name=$1 kind=$2 file
  shift 2
  "$MAKE" "$kind" "${PIPELINE_INPUT_DIR}/${name}.tif"
  file="${PIPELINE_LAYERS_DIR}/${name}.yaml"
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.yaml" "$file"
  set_layer "$file" ".source.path = \"${name}.tif\"" "$@"
}

# level_opts LEVEL: the open option for COG level LEVEL (0 the full
# resolution, the max zoom; 1 the first overview, one zoom down; ...).
level_opts() {
  if (($1 > 0)); then printf '%s\n' -oo "OVERVIEW_LEVEL=$(($1 - 1))"; fi
}

# value_at COG LEVEL X Y: the value at Albers metres X Y (make_raster.sh's
# CRS) in level LEVEL of COG.
value_at() {
  local cog=$1 level=$2 lonlat opts
  lonlat=$(echo "$3 $4" | gdaltransform -output_xy -t_srs EPSG:4326 \
    -s_srs "$(gdalsrsinfo -o proj4 "${PIPELINE_INPUT_DIR}/cover.tif")")
  mapfile -t opts < <(level_opts "$level")
  # shellcheck disable=SC2086 # lonlat is two numbers.
  gdallocationinfo -valonly -wgs84 "${opts[@]}" "$cog" $lonlat
}

# level_values COG LEVEL: every pixel value in level LEVEL of COG within
# the layer's bounds (build.json's, of its only entry), one per line. The
# COG itself is padded to the tile grid, mostly empty.
level_values() {
  local opts bounds
  mapfile -t opts < <(level_opts "$2")
  bounds=$(jq -r '.layers[0].bounds | "\(.[0]) \(.[3]) \(.[2]) \(.[1])"' "$BUILD")
  # shellcheck disable=SC2086 # bounds is four numbers.
  gdal_translate -q -of XYZ "${opts[@]}" -projwin $bounds -projwin_srs EPSG:4326 \
    "$1" /vsistdout/ | awk '{ print $3 }'
}

# level_sum COG LEVEL: the sum of level_values (the share covered, summed:
# comparable between builds of one source extent).
level_sum() {
  level_values "$1" "$2" | awk '{ s += $1 } END { printf "%d\n", s }'
}


@test "the raster fixture is a binary Byte raster in the strip layout" {
  "$MAKE" byte "${BATS_TEST_TMPDIR}/b.tif"
  run jq -e '.bands[0] | .type == "Byte" and .noDataValue == 255 and .block == [400, 1]
    and .minimum == 1 and .maximum == 1' <<<"$(gdalinfo -json -stats "${BATS_TEST_TMPDIR}/b.tif")"
  [ "$status" -eq 0 ]
}

@test "builds a raster layer: one Web Mercator COG with an overview per lower zoom" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ -s "$COG" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/cover.pmtiles" ]
  assert_no_temp_files

  run jq -e '.metadata.IMAGE_STRUCTURE.LAYOUT == "COG"
    and .metadata.IMAGE_STRUCTURE.COMPRESSION == "ZSTD"
    and .stac["proj:epsg"] == 3857
    and (.bands | length) == 1
    and (.bands[0] | .type == "Byte" and .block == [256, 256]
         and (has("noDataValue") | not) and (.overviews | length) == 5)' \
    <<<"$(gdalinfo -json "$COG")"
  [ "$status" -eq 0 ]
}

@test "the COG is on the tile grid: its 256 px blocks are the map's tiles" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  # The origin is a whole number of z8 tiles (z8 is the max zoom, level 0)
  # from the grid's top left, and each overview halves the size exactly.
  run jq -e '(40075016.68557849 / 256) as $tile
    | ((.geoTransform[0] + 20037508.342789244) / $tile) as $x
    | ((20037508.342789244 - .geoTransform[3]) / $tile) as $y
    | (($x - ($x | round)) | fabs) < 1e-6 and (($y - ($y | round)) | fabs) < 1e-6
      and ([.bands[0].overviews[].size] == [range(1; 6) as $k
            | [.size[0] / pow(2; $k), .size[1] / pow(2; $k)]])' \
    <<<"$(gdalinfo -json "$COG")"
  [ "$status" -eq 0 ]
}

@test "values are the share covered: 0 or 255 at the max zoom, partial below" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]

  # Inside rectangle 2, and outside every shape (nodata 255 in the source).
  [ "$(value_at "$COG" 0 390000 1350000)" -eq 255 ]
  [ "$(value_at "$COG" 0 110000 1210000)" -eq 0 ]
  # The z8 level holds only 0 and 255: every pixel is all or nothing.
  run level_values "$COG" 0
  [ "$status" -eq 0 ]
  [ "$(sort -nu <<<"$output" | paste -sd' ')" = "0 255" ]
  # The z3 level (5 overviews down) averages: partial values appear.
  run level_sum "$COG" 5
  ((output > 0 && output % 255 != 0))
}

@test "the build.json entry says raster and cog, with the COG's build report" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]

  run jq -e '.layers[0]
    | .name == "cover" and .file == "cover.cog.tif"
      and .type == "raster" and .format == "cog"
      and .minzoom == 3 and .maxzoom == 8
      and (.bounds[0] | . > -100 and . < -90) and (.bounds[1] | . > 45 and . < 60)
      and .center[2] == 3
      and (.build_seconds | type == "number")
      and .bytes > 0 and .block_size == 256 and .overview_count == 5
      and .resampling == "near" and .max_zoom_values == "near" and .grey_levels == 256
      and .width > 0 and .height > 0
      and ([.zooms[].zoom] == [8, 7, 6, 5, 4, 3])
      and .zooms[0].width == .width and .zooms[0].height == .height
      and .zooms[5].width * 32 == .width
      and (has("tile_count") | not) and (has("feature_count") | not)' "$BUILD"
  [ "$status" -eq 0 ]
  [ "$(jq '.layers[0].bytes' "$BUILD")" -eq "$(stat -c %s "$COG")" ]

  run jq -e '.layers[0] | (has("display") or has("enabled")) | not' "$BUILD"
  [ "$status" -eq 0 ]
  run jq -e --argjson f "$(yq -o json -I 0 . "${PIPELINE_LAYERS_DIR}/cover.yaml")" '
    .metadata["erap:layers"].cover == {title: $f.title, type: "raster", order: ($f.order // 0),
      visible: ($f.visible // false), legend: $f.display.legend}
    and .layers[0].paint == $f.display.layers[0].paint' "$STYLE"
  [ "$status" -eq 0 ]
}

@test "a Float32 0/1 raster with NaN nodata builds; 0 and nodata are left out" {
  raster_layer ag float
  run "$RUN" ag
  [ "$status" -eq 0 ]
  local float_sum
  float_sum=$(level_sum "${PIPELINE_OUTPUT_DIR}/ag.cog.tif" 5)

  # The same shapes as the byte raster, less the left quarter (NaN).
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local byte_sum
  byte_sum=$(level_sum "$COG" 5)
  ((float_sum > 0 && float_sum < byte_sum))
}

@test "source.nodata sets the nodata of a source that does not declare it" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local declared
  declared=$(level_sum "$COG" 5)

  # Without its nodata value, the 255 cells count as covered: more cover.
  gdal raster edit --nodata none "${PIPELINE_INPUT_DIR}/cover.tif"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  (($(level_sum "$COG" 5) > declared))

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.source.nodata = 255'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(level_sum "$COG" 5)" -eq "$declared" ]
}

@test "a raster with no 1 cells fails and writes nothing" {
  raster_layer empty empty
  run "$RUN" empty
  [ "$status" -eq 1 ]
  [[ $output == *"no cover"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/empty.cog.tif" ]
  [ ! -e "$BUILD" ]
  assert_no_temp_files
}

@test "building one raster layer keeps the vector layer's entry; style.json has both" {
  cp "${PIPELINE_ROOT}/tests/layers/sample.yaml" "$PIPELINE_LAYERS_DIR"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  local before
  before=$(jq -c '.layers[] | select(.name == "sample")' "$BUILD")

  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output != *"layer sample: start"* ]]
  [ "$(jq -c '.layers[] | select(.name == "sample")' "$BUILD")" = "$before" ]
  run jq -r '[.layers[] | "\(.name):\(.type)"] | join(",")' "$BUILD"
  [ "$output" = "cover:raster,sample:vector" ]

  # style.json: a cog:// raster-dem source and the color-relief layer, under
  # the vector layer (order 5 < 10), with no source layer.
  run jq -e '
    .sources.cover == {type: "raster-dem", tileSize: 256, url: "cog://cover.cog.tif#dem"}
    and .sources.sample == {type: "vector", url: "pmtiles://sample.pmtiles"}
    and ([.layers[].id] == ["cover-raster", "sample-fill", "sample-outline"])
    and (.layers[0] | .type == "color-relief" and .source == "cover"
         and (has("source-layer") | not))' "$STYLE"
  [ "$status" -eq 0 ]
}

@test "the colour lives in the style: recolouring gives the same COG values" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local before
  before=$(level_sum "$COG" 0)

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" \
    '.display.layers[0].paint["color-relief-color"][6] = "rgba(255, 0, 0, 1)"'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(level_sum "$COG" 0)" -eq "$before" ]
  run jq -r '.layers[0].paint["color-relief-color"] | "\(.[5]) \(.[6])"' "$STYLE"
  [ "$output" = "255 rgba(255, 0, 0, 1)" ]
}

@test "a bad raster layer file fails before preparing and keeps the previous COG" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$COG")

  # A pop-up on a raster layer.
  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.display.popup = {"title": "{x}", "sections": [{"description": "x"}]}'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"cover.yaml: at '/display/popup'"* ]]
  [[ $output != *"preparing"* ]]

  # Vector settings on a raster layer.
  raster_layer cover byte '.fields.keep = ["a"]' '.source.id = "id"'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"cover.yaml: at '/fields'"* ]]
  [[ $output == *"cover.yaml: at '/source/id'"* ]]

  [ "$(sha256sum "$COG")" = "$before" ]
  assert_no_temp_files
}

@test "raster layer checks: max zoom limit, nodata" {
  raster_layer cover byte '.processing.maxzoom = 15'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"cover.yaml: at '/processing/maxzoom'"* ]]

  raster_layer cover byte '.source.nodata = "none"'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"cover.yaml: at '/source/nodata'"* ]]

  raster_layer cover byte '.processing.minzoom = 9'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"processing: minzoom (9) is above maxzoom (8)"* ]]
}

@test "--style-only of a layer built as raster but now vector is an error" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  layer_file "${PIPELINE_LAYERS_DIR}/cover.yaml"
  run "$RUN" --style-only cover
  [ "$status" -eq 1 ]
  [[ $output == *"built as a raster layer, but cover.yaml is a vector layer now: rebuild it"* ]]
}

@test "a raster built as PNG tiles before COGs is stale, and a rebuild replaces it" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  # Make the build look like one from before COGs (ADR 0008).
  mv "$COG" "${PIPELINE_OUTPUT_DIR}/cover.pmtiles"
  jq '.layers[0] |= (.file = "cover.pmtiles" | .format = "png" | .tile_count = 10
    | .max_tile_bytes = 100 | del(.width, .height, .block_size, .overview_count, .zooms))' \
    "$BUILD" >"${BUILD}.new"
  mv "${BUILD}.new" "$BUILD"

  run "$RUN" --status --json cover
  [ "$status" -eq 0 ]
  run jq -e '.layers[0] | .state == "stale" and .format == "png" and .tile_count == 10
    and .archive_bytes > 0 and any(.notes[]; test("rebuild it as a COG"))' <<<"$output"
  [ "$status" -eq 0 ]

  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"removed the old archive cover.pmtiles"* ]]
  [ -s "$COG" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/cover.pmtiles" ]
  run "$RUN" --status --json cover
  [ "$status" -eq 0 ]
  run jq -e '.layers[0] | .state == "current" and .format == "cog" and .width > 0
    and .tile_count == null' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "--remove deletes a raster layer's COG and any older .pmtiles" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  echo old >"${PIPELINE_OUTPUT_DIR}/cover.pmtiles"
  run "$RUN" --remove cover
  [ "$status" -eq 0 ]
  [ ! -e "$COG" ]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/cover.pmtiles" ]
  run jq -e '.layers == []' "$BUILD"
  [ "$status" -eq 0 ]
}

@test "prepare: the source becomes a tiled 0/255 Byte GeoTIFF with no nodata, kept in the work dir" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"preparing"* ]]
  local cache="${PIPELINE_WORK_DIR}/raster"
  run find "$cache" -name '*.tif'
  [ "$(wc -l <<<"$output")" -eq 1 ]
  local prepared=$output
  # Nodata (255) became 0; the 1 cells became 255.
  run jq -e '.bands[0] | .type == "Byte" and .block == [512, 512]
    and (has("noDataValue") | not) and .minimum == 0 and .maximum == 255' \
    <<<"$(gdalinfo -json -stats "$prepared")"
  [ "$status" -eq 0 ]
  # The key beside it names the source.
  run jq -e --arg p "${PIPELINE_INPUT_DIR}/cover.tif" '.path == $p and .size > 0 and .mtime > 0' \
    "${prepared%.tif}.json"
  [ "$status" -eq 0 ]
  run find "$cache" -name '*.tmp*'
  [ -z "$output" ]
}

@test "prepare: a Float32 source with NaN nodata becomes 0/255 Byte" {
  raster_layer ag float
  run "$RUN" ag
  [ "$status" -eq 0 ]
  local prepared
  prepared=$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')
  run jq -e '.bands[0] | .type == "Byte" and (has("noDataValue") | not)
    and .minimum == 0 and .maximum == 255' <<<"$(gdalinfo -json -stats "$prepared")"
  [ "$status" -eq 0 ]
}

@test "prepare: a rebuild reuses the prepared source and gives the same COG" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local prepared before levels sum
  prepared=$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')
  before=$(stat -c %y "$prepared")
  levels=$(jq -c '.layers[0].zooms' "$BUILD")
  sum=$(level_sum "$COG" 0)

  # Another zoom range: the same prepared source.
  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.maxzoom = 7'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"prepared source cached"* ]]
  [[ $output != *"preparing"* ]]
  [ "$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')" = "$prepared" ]
  [ "$(stat -c %y "$prepared")" = "$before" ]

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.maxzoom = 8'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(jq -c '.layers[0].zooms' "$BUILD")" = "$levels" ]
  [ "$(level_sum "$COG" 0)" -eq "$sum" ]
}

@test "prepare: a changed source or source.nodata is prepared again, replacing the old file" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local first
  first=$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')

  # Same path, new modification time.
  touch -d '2020-01-01' "${PIPELINE_INPUT_DIR}/cover.tif"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"preparing"* ]]
  local second
  second=$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')
  [ -n "$second" ] && [ "$second" != "$first" ]
  [ "$(find "${PIPELINE_WORK_DIR}/raster" -type f | wc -l)" -eq 2 ] # .tif and .json

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.source.nodata = 255'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"preparing"* ]]
  [ "$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif' | wc -l)" -eq 1 ]
  [ "$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')" != "$second" ]
}

@test "prepare: an empty PIPELINE_WORK_DIR caches nothing" {
  raster_layer cover byte
  PIPELINE_WORK_DIR="" run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"preparing"* ]]
  [ ! -e "${PIPELINE_WORK_DIR}/raster" ]
  [ -s "$COG" ]
}

@test "prepare: an unwritable work dir fails the layer before tiling" {
  raster_layer cover byte
  mkdir -p "${PIPELINE_WORK_DIR}"
  chmod a-w "${PIPELINE_WORK_DIR}"
  run "$RUN" cover
  chmod u+w "${PIPELINE_WORK_DIR}"
  [ "$status" -eq 1 ]
  [[ $output == *"cannot create ${PIPELINE_WORK_DIR}/raster"* ]]
  [ ! -e "$COG" ]
}

@test "lower zooms average the share: the checkerboard reads as about half covered at z4" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  # The middle of the 20 km checkerboard of 2 km squares (make_raster.sh),
  # at z4: level 4 (z8 is level 0).
  run value_at "$COG" 4 150000 1330000
  [ "$status" -eq 0 ]
  ((output >= 90 && output <= 165))
}

# raster_fn FUNCTION ARG...: run a lib/raster.sh function in a subshell.
raster_fn() {
  (
    # shellcheck source=lib/log.sh
    source "${PIPELINE_ROOT}/lib/log.sh"
    # shellcheck source=lib/raster.sh
    source "${PIPELINE_ROOT}/lib/raster.sh"
    "$@"
  )
}

@test "resampling: average when the max zoom's pixel is coarser on the ground than the source's" {
  # 30 m data at Canada's middle (62.4 N): z12 is 17.7 m on the ground, z11
  # 35.4 m.
  run raster_fn raster_resampling 30 62.4 12
  [ "$status" -eq 0 ]
  [ "$output" = near ]
  run raster_fn raster_resampling 30 62.4 11
  [ "$output" = average ]
  # At the equator z12 is 38.2 m: coarser than 30 m, finer than 40 m.
  run raster_fn raster_resampling 30 0 12
  [ "$output" = average ]
  run raster_fn raster_resampling 40 0 12
  [ "$output" = near ]
  # The 1 km fixture near 52 N: z6 is about 1500 m, z7 about 750 m.
  run raster_fn raster_resampling 1000 52 6
  [ "$output" = average ]
  run raster_fn raster_resampling 1000 52 7
  [ "$output" = near ]
}

@test "the source pixel's ground size and centre latitude, projected or geographic" {
  "$MAKE" byte "${BATS_TEST_TMPDIR}/b.tif"
  run raster_fn raster_ground_pixel "${BATS_TEST_TMPDIR}/b.tif"
  [ "$status" -eq 0 ]
  read -r size lat <<<"$output"
  awk -v s="$size" -v l="$lat" 'BEGIN { exit !(s == 1000 && l > 45 && l < 60) }'

  # Geographic, 0.01 degrees: about 1113 m north to south, the larger side.
  gdalwarp -q -t_srs EPSG:4326 -tr 0.01 0.01 "${BATS_TEST_TMPDIR}/b.tif" "${BATS_TEST_TMPDIR}/g.tif"
  run raster_fn raster_ground_pixel "${BATS_TEST_TMPDIR}/g.tif"
  [ "$status" -eq 0 ]
  read -r size lat <<<"$output"
  awk -v s="$size" -v l="$lat" 'BEGIN { exit !(s > 1110 && s < 1115 && l > 45 && l < 60) }'

  # No CRS in the file: the one given (source.srs) is used.
  local crs
  crs=$(gdalsrsinfo -o proj4 "${BATS_TEST_TMPDIR}/b.tif")
  cp "${BATS_TEST_TMPDIR}/b.tif" "${BATS_TEST_TMPDIR}/n.tif"
  gdal raster edit --crs none "${BATS_TEST_TMPDIR}/n.tif"
  [ "$(gdalinfo -json "${BATS_TEST_TMPDIR}/n.tif" | jq -r '.coordinateSystem.wkt // ""')" = "" ]
  run raster_fn raster_ground_pixel "${BATS_TEST_TMPDIR}/n.tif" "$crs"
  [ "$status" -eq 0 ]
  read -r size lat <<<"$output"
  awk -v s="$size" -v l="$lat" 'BEGIN { exit !(s == 1000 && l > 45 && l < 60) }'
}

@test "a max zoom coarser than the source averages, binary by majority, overviews like a finer build's" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"resampling near"* ]]
  [[ $output != *"majority"* ]]
  [ "$(jq -r '.layers[0] | "\(.resampling) \(.max_zoom_values)"' "$BUILD")" = "near near" ]
  # z5 in the z8 build: three overviews down.
  local overview
  overview=$(level_sum "$COG" 3)

  # z6 is about 1500 m on the ground, coarser than the 1 km source.
  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.maxzoom = 6'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"resampling average"* ]]
  [[ $output == *"binary by majority"* ]]
  [ "$(jq -r '.layers[0] | "\(.resampling) \(.max_zoom_values)"' "$BUILD")" = "average majority" ]
  # Only 0 and 255 at the max zoom ...
  run level_values "$COG" 0
  [ "$status" -eq 0 ]
  [ "$(sort -nu <<<"$output" | paste -sd' ')" = "0 255" ]
  # ... and the first overview has the same share covered as the z8
  # build's z5 overview, within 2%.
  local averaged
  averaged=$(level_sum "$COG" 1)
  awk -v a="$averaged" -v b="$overview" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= b * 0.02) }'
}

# reference_warp MAX_ZOOM METHOD OUT: the cover layer's prepared source
# (in the work dir) warped and given overviews down to z3 as the pipeline
# does before the COG copy (raster_warp, raster_overviews).
reference_warp() {
  local prepared
  prepared=$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')
  [ "$(wc -l <<<"$prepared")" -eq 1 ]
  raster_fn raster_warp "$prepared" "$(raster_fn raster_snap_zoom 3 "$1")" "$1" "$3" "$2"
  raster_fn raster_overviews "$3" "$(($1 - 3))"
}

@test "majority: 255 where the averaged share is at least 128; the overviews are the full averaged shares" {
  raster_layer cover byte '.processing.maxzoom = 6'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  run jq -e '.metadata.IMAGE_STRUCTURE.LAYOUT == "COG" and (.bands[0] | .type == "Byte"
    and .block == [256, 256] and (has("noDataValue") | not) and (.overviews | length) == 3)' \
    <<<"$(gdalinfo -json "$COG")"
  [ "$status" -eq 0 ]
  local ref="${BATS_TEST_TMPDIR}/ref.tif"
  reference_warp 6 average "$ref"

  # The max zoom: the averaged share, 0/255 by majority. Shares below and
  # above half, not only 0 and 255, are in the averaged raster.
  run paste <(level_values "$ref" 0) <(level_values "$COG" 0)
  [ "$status" -eq 0 ]
  run awk '$2 != ($1 >= 128 ? 255 : 0) { bad++ }
    $1 > 0 && $1 < 128 { low++ } $1 >= 128 && $1 < 255 { high++ }
    END { printf "%d %d %d %d\n", bad, low, high, NR }' <<<"$output"
  read -r bad low high count <<<"$output"
  ((bad == 0 && low > 0 && high > 0 && count > 1000))

  # Every overview: the averaged one, value for value, with partial shares
  # (so averaged from the full shares, not from the binary max zoom).
  local level
  for level in 1 2 3; do
    cmp <(level_values "$ref" "$level") <(level_values "$COG" "$level")
  done
  [ "$(level_values "$COG" 3 | awk '$1 > 0 && $1 < 255' | wc -l)" -gt 0 ]
  assert_no_temp_files
}

@test "near: the COG is the warped raster and its overviews as they are" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local ref="${BATS_TEST_TMPDIR}/ref.tif"
  reference_warp 8 near "$ref"
  raster_fn raster_cog "$ref" "${BATS_TEST_TMPDIR}/ref.cog.tif"
  [ "$(sha256sum <"${BATS_TEST_TMPDIR}/ref.cog.tif")" = "$(sha256sum <"$COG")" ]
}

# The 8 grey levels of grey_levels 8: round(k * 255 / 7), k = 0 to 7.
GREY8="0 36 73 109 146 182 219 255"

@test "grey_levels must be an integer from 2 to 256" {
  local bad
  for bad in 1 257 '"abc"' 2.5 '""'; do
    raster_layer cover byte ".processing.grey_levels = ${bad}"
    run "$RUN" cover
    [ "$status" -eq 1 ]
    [[ $output == *"cover.yaml: at '/processing/grey_levels'"* ]]
  done
  [ ! -e "$COG" ]
}

@test "the default of 256 grey levels adds no step and gives the same COG" {
  raster_layer cover byte '.processing.maxzoom = 6'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output != *"grey levels"* ]]
  [ "$(jq '.layers[0].grey_levels' "$BUILD")" -eq 256 ]
  local before
  before=$(sha256sum <"$COG")

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.grey_levels = 256'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output != *"grey levels"* ]]
  [ "$(sha256sum <"$COG")" = "$before" ]
}

@test "grey_levels 8: every overview holds only 8 values, from the full shares, and cover never becomes 0" {
  # z6 averages at the max zoom (coarser than the 1 km source), so the max
  # zoom is binary by majority and the 8 levels are in the overviews.
  raster_layer cover byte '.processing.maxzoom = 6'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  cp "$COG" "${BATS_TEST_TMPDIR}/full.cog.tif"

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.grey_levels = 8'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"8 grey levels"* ]]
  [ "$(jq '.layers[0].grey_levels' "$BUILD")" -eq 8 ]
  # Still a valid COG: the same layout, block size and overviews.
  run jq -e '.metadata.IMAGE_STRUCTURE.LAYOUT == "COG" and (.bands[0] | .type == "Byte"
    and .block == [256, 256] and (has("noDataValue") | not) and (.overviews | length) == 3)' \
    <<<"$(gdalinfo -json "$COG")"
  [ "$status" -eq 0 ]

  # The max zoom: binary by majority, as with 256 levels.
  cmp <(level_values "${BATS_TEST_TMPDIR}/full.cog.tif" 0) <(level_values "$COG" 0)
  [ "$(level_values "$COG" 0 | sort -nu | paste -sd' ')" = "0 255" ]

  local level small=0
  for level in 1 2 3; do
    # Only the 8 values in every overview ...
    run level_values "$COG" "$level"
    [ "$status" -eq 0 ]
    run comm -23 <(sort -u <<<"$output") <(tr ' ' '\n' <<<"$GREY8" | sort)
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # ... each the level nearest the full share of the 256-level build
    # (within half a step, 18.2), so the overviews average the full shares;
    # 0 only where that is 0, and any cover at least 36.
    run paste <(level_values "${BATS_TEST_TMPDIR}/full.cog.tif" "$level") \
      <(level_values "$COG" "$level")
    [ "$status" -eq 0 ]
    run awk '{ d = $2 - $1; if (d < 0) d = -d }
      ($1 == 0) != ($2 == 0) || ($1 > 0 && $1 < 18 && $2 != 36) || ($1 >= 18 && d > 18.3) { bad++ }
      $1 > 0 && $1 < 18 { small++ }
      END { printf "%d %d\n", bad, small }' <<<"$output"
    [ "${output% *}" -eq 0 ]
    small=$((small + ${output#* }))
  done
  # Some cover was small enough to round to 0, and did not.
  ((small > 0))
  assert_no_temp_files
}

@test "raster_grey_lut: the nearest level, any cover at least the first level above 0" {
  run raster_fn raster_grey_lut 8
  [ "$status" -eq 0 ]
  [ "$output" = "0:0,1:36,54:36,55:73,91:73,92:109,127:109,128:146,163:146,164:182,200:182,201:219,236:219,237:255,255:255" ]
  run raster_fn raster_grey_lut 2
  [ "$output" = "0:0,1:255,255:255" ]
}
