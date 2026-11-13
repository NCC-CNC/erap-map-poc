#!/usr/bin/env bats
# Raster layer tests (LAYER_TYPE=raster, lib/raster.sh, ADR 0008 and 0010)
# on synthetic binary GeoTIFFs made at test time by fixtures/make_raster.sh
# (no committed .tif). Run in the test image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  MAKE="${PIPELINE_ROOT}/tests/fixtures/make_raster.sh"
  TOOL="${PIPELINE_ROOT}/style/cli.mjs"
  EXPECTED="${PIPELINE_ROOT}/tests/fixtures/expected_raster_display.json"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_WORK_DIR="${BATS_TEST_TMPDIR}/work"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
  COG="${PIPELINE_OUTPUT_DIR}/cover.cog.tif"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# raster_layer NAME KIND [SETTING...]: make a KIND raster (make_raster.sh)
# and a raster layer config for it, z3 to z8, with the test display config.
raster_layer() {
  local name=$1 kind=$2
  shift 2
  "$MAKE" "$kind" "${PIPELINE_INPUT_DIR}/${name}.tif"
  printf '%s\n' 'LAYER_TYPE=raster' "LAYER_INPUT=${name}.tif" \
    'LAYER_MIN_ZOOM=3' 'LAYER_MAX_ZOOM=8' "$@" >"${PIPELINE_LAYERS_DIR}/${name}.env"
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" "${PIPELINE_LAYERS_DIR}/${name}.style.json"
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
# the layer's bounds (the manifest's, of its only entry), one per line. The
# COG itself is padded to the tile grid, mostly empty.
level_values() {
  local opts bounds
  mapfile -t opts < <(level_opts "$2")
  bounds=$(jq -r '.layers[0].bounds | "\(.[0]) \(.[3]) \(.[2]) \(.[1])"' "$MANIFEST")
  # shellcheck disable=SC2086 # bounds is four numbers.
  gdal_translate -q -of XYZ "${opts[@]}" -projwin $bounds -projwin_srs EPSG:4326 \
    "$1" /vsistdout/ | awk '{ print $3 }'
}

# level_sum COG LEVEL: the sum of level_values (the share covered, summed:
# comparable between builds of one source extent).
level_sum() {
  level_values "$1" "$2" | awk '{ s += $1 } END { printf "%d\n", s }'
}

assert_no_temp_files() {
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

@test "the manifest entry says raster and cog, with the COG's build report" {
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
      and .width > 0 and .height > 0
      and ([.zooms[].zoom] == [8, 7, 6, 5, 4, 3])
      and .zooms[0].width == .width and .zooms[0].height == .height
      and .zooms[5].width * 32 == .width
      and (has("tile_count") | not) and (has("feature_count") | not)' "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$(jq '.layers[0].bytes' "$MANIFEST")" -eq "$(stat -c %s "$COG")" ]

  run jq -e --slurpfile want "$EXPECTED" '.layers[0].display == $want[0]' "$MANIFEST"
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

@test "LAYER_NODATA sets the nodata of a source that does not declare it" {
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

  echo 'LAYER_NODATA=255' >>"${PIPELINE_LAYERS_DIR}/cover.env"
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
  [ ! -e "$MANIFEST" ]
  assert_no_temp_files
}

@test "building one raster layer keeps the vector layer's entry; style.json has both" {
  cp "${PIPELINE_ROOT}"/tests/layers/sample.env "${PIPELINE_ROOT}"/tests/layers/sample.style.json "$PIPELINE_LAYERS_DIR"
  run "$RUN" sample
  [ "$status" -eq 0 ]
  local before
  before=$(jq -c '.layers[] | select(.name == "sample")' "$MANIFEST")

  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output != *"layer sample: start"* ]]
  [ "$(jq -c '.layers[] | select(.name == "sample")' "$MANIFEST")" = "$before" ]
  run jq -r '[.layers[] | "\(.name):\(.type)"] | join(",")' "$MANIFEST"
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

  jq '.symbology.color = "#ff0000"' "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" \
    >"${PIPELINE_LAYERS_DIR}/cover.style.json"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(level_sum "$COG" 0)" -eq "$before" ]
  run jq -r '.layers[0].paint["color-relief-color"] | "\(.[5]) \(.[6])"' "$STYLE"
  [ "$output" = "255 rgba(255, 0, 0, 1)" ]
}

@test "a bad raster display config fails before tiling and keeps the previous COG" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$COG")

  # A vector shorthand on a raster layer.
  cp "${PIPELINE_ROOT}/tests/fixtures/minimal.style.json" "${PIPELINE_LAYERS_DIR}/cover.style.json"
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *'needs "symbology" with "geometry": "raster"'* ]]
  [[ $output != *"preparing"* ]]

  # A pop-up on a raster layer.
  jq '.popup = {title: {attribute: "x"}, stats: []}' "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" \
    >"${PIPELINE_LAYERS_DIR}/cover.style.json"
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"raster layers are display only"* ]]

  # A colour that is not #rrggbb.
  jq '.symbology.color = "green"' "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" \
    >"${PIPELINE_LAYERS_DIR}/cover.style.json"
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"/symbology/color must match pattern"* ]]

  [ "$(sha256sum "$COG")" = "$before" ]
  assert_no_temp_files
}

@test "the raster shorthand on a vector layer is rejected" {
  cp "${PIPELINE_ROOT}/tests/layers/sample.env" "$PIPELINE_LAYERS_DIR"
  cp "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" "${PIPELINE_LAYERS_DIR}/sample.style.json"
  run "$RUN" sample
  [ "$status" -eq 1 ]
  [[ $output == *'"geometry": "raster" is for raster layers only'* ]]
}

@test "raster config checks: LAYER_TYPE, max zoom limit, LAYER_NODATA" {
  raster_layer cover byte 'LAYER_TYPE=grid'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_TYPE must be vector or raster"* ]]

  raster_layer cover byte 'LAYER_MAX_ZOOM=15'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_MAX_ZOOM must be at most 14"* ]]

  raster_layer cover byte 'LAYER_NODATA=none'
  run "$RUN" cover
  [ "$status" -eq 1 ]
  [[ $output == *"LAYER_NODATA must be a number or nan"* ]]
}

@test "the repo's raster layer configs pass the pre-check" {
  run node "$TOOL" check "${PIPELINE_ROOT}/layers/forest.style.json" \
    "${PIPELINE_ROOT}/layers/agriculture.style.json"
  [ "$status" -eq 0 ]
  [[ $output == *"forest.style.json: ok"* ]]
  [[ $output == *"agriculture.style.json: ok"* ]]
}

@test "a raster built as PNG tiles before COGs is stale, and a rebuild replaces it" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  # Make the build look like one from before COGs (ADR 0008).
  mv "$COG" "${PIPELINE_OUTPUT_DIR}/cover.pmtiles"
  jq '.layers[0] |= (.file = "cover.pmtiles" | .format = "png" | .tile_count = 10
    | .max_tile_bytes = 100 | del(.width, .height, .block_size, .overview_count, .zooms))' \
    "$MANIFEST" >"${MANIFEST}.new"
  mv "${MANIFEST}.new" "$MANIFEST"

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
  run jq -e '.layers == []' "$MANIFEST"
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
  levels=$(jq -c '.layers[0].zooms' "$MANIFEST")
  sum=$(level_sum "$COG" 0)

  # Another zoom range: the same prepared source.
  sed -i 's/^LAYER_MAX_ZOOM=8$/LAYER_MAX_ZOOM=7/' "${PIPELINE_LAYERS_DIR}/cover.env"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"prepared source cached"* ]]
  [[ $output != *"preparing"* ]]
  [ "$(find "${PIPELINE_WORK_DIR}/raster" -name '*.tif')" = "$prepared" ]
  [ "$(stat -c %y "$prepared")" = "$before" ]

  sed -i 's/^LAYER_MAX_ZOOM=7$/LAYER_MAX_ZOOM=8/' "${PIPELINE_LAYERS_DIR}/cover.env"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(jq -c '.layers[0].zooms' "$MANIFEST")" = "$levels" ]
  [ "$(level_sum "$COG" 0)" -eq "$sum" ]
}

@test "prepare: a changed source or LAYER_NODATA is prepared again, replacing the old file" {
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

  echo 'LAYER_NODATA=255' >>"${PIPELINE_LAYERS_DIR}/cover.env"
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
