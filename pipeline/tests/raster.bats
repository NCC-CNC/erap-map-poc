#!/usr/bin/env bats
# Raster layer tests (LAYER_TYPE=raster, lib/raster.sh, ADR 0008) on
# synthetic binary GeoTIFFs made at test time by fixtures/make_raster.sh (no
# committed .tif). Run in the test image with the other bats files:
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
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  MANIFEST="${PIPELINE_OUTPUT_DIR}/manifest.json"
  STYLE="${PIPELINE_OUTPUT_DIR}/style.json"
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

# tile_at ARCHIVE Z: `x y` of the tile at zoom Z holding the archive's centre.
tile_at() {
  pmtiles show --header-json "$1" | jq -r '.center | "\(.[0]) \(.[1])"' \
    | awk -v z="$2" '{
        pi = atan2(0, -1); n = 2 ^ z; r = $2 * pi / 180
        x = int(($1 + 180) / 360 * n)
        y = int((1 - log(sin(r) / cos(r) + 1 / cos(r)) / pi) / 2 * n)
        print x, y
      }'
}

# grey_values ARCHIVE Z X Y: the distinct grey levels of the opaque pixels of
# one tile, ascending, space-separated.
grey_values() {
  local png="${BATS_TEST_TMPDIR}/tile.png"
  pmtiles tile "$1" "$2" "$3" "$4" >"$png"
  [[ $(gdalinfo -json "$png" | jq '.bands | length') == 2 ]] || return 1
  paste <(gdal_translate -q -of XYZ -b 1 "$png" /vsistdout/ | awk '{ print $3 }') \
    <(gdal_translate -q -of XYZ -b 2 "$png" /vsistdout/ | awk '{ print $3 }') \
    | awk '$2 > 0 { print $1 }' | sort -nu | paste -sd' '
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

@test "builds a raster layer: grey PNG tiles in a .pmtiles archive, z3 to z8" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/cover.pmtiles"
  [ -s "$archive" ]
  assert_no_temp_files

  run jq -e '.tile_type == "png" and .minzoom == 3 and .maxzoom == 8
    and (.bounds[0] | . > -100 and . < -90) and (.bounds[1] | . > 45 and . < 60)' \
    <<<"$(pmtiles show --header-json "$archive")"
  [ "$status" -eq 0 ]
}

@test "tiles hold the share covered: full at the max zoom, partial below" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/cover.pmtiles" x y

  # z8: nearest from the prepared raster, so only full cover (255).
  read -r x y < <(tile_at "$archive" 8)
  run grey_values "$archive" 8 "$x" "$y"
  [ "$status" -eq 0 ]
  [ "$output" = "255" ]

  # z3: averaged, so edges and the checkerboard give partial cover.
  read -r x y < <(tile_at "$archive" 3)
  run grey_values "$archive" 3 "$x" "$y"
  [ "$status" -eq 0 ]
  [[ $output == *" "* ]]
}

@test "the manifest entry says raster and png, with the build report" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]

  run jq -e '.layers[0]
    | .name == "cover" and .file == "cover.pmtiles"
      and .type == "raster" and .format == "png"
      and .minzoom == 3 and .maxzoom == 8
      and (.build_seconds | type == "number")
      and .bytes > 0 and .tile_count > 0
      and ([.zooms[].zoom] == [range(3; 9)])
      and .tile_count == ([.zooms[].tiles] | add)
      and .max_tile_bytes == ([.zooms[].max_tile_bytes] | max)
      and (has("feature_count") | not)' "$MANIFEST"
  [ "$status" -eq 0 ]

  run jq -e --slurpfile want "$EXPECTED" '.layers[0].display == $want[0]' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "a Float32 0/1 raster with NaN nodata builds; 0 and nodata are left out" {
  raster_layer ag float
  run "$RUN" ag
  [ "$status" -eq 0 ]
  local float_tiles
  float_tiles=$(jq '.layers[0].tile_count' "$MANIFEST")

  # The same shapes as the byte raster, less the left quarter (NaN).
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local byte_tiles
  byte_tiles=$(jq '.layers[] | select(.name == "cover") | .tile_count' "$MANIFEST")
  ((float_tiles > 0 && float_tiles < byte_tiles))
}

@test "LAYER_NODATA sets the nodata of a source that does not declare it" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local declared
  declared=$(jq '.layers[0].tile_count' "$MANIFEST")

  # Without its nodata value, the 255 cells count as covered: more tiles.
  gdal raster edit --nodata none "${PIPELINE_INPUT_DIR}/cover.tif"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  (($(jq '.layers[0].tile_count' "$MANIFEST") > declared))

  echo 'LAYER_NODATA=255' >>"${PIPELINE_LAYERS_DIR}/cover.env"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(jq '.layers[0].tile_count' "$MANIFEST")" -eq "$declared" ]
}

@test "a raster with no 1 cells fails and writes nothing" {
  raster_layer empty empty
  run "$RUN" empty
  [ "$status" -eq 1 ]
  [[ $output == *"no tiles"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/empty.pmtiles" ]
  [ ! -e "$MANIFEST" ]
  assert_no_temp_files
}

@test "building one raster layer keeps the vector layer's entry; style.json has both" {
  cp "${PIPELINE_ROOT}"/layers/sample.env "${PIPELINE_ROOT}"/layers/sample.style.json "$PIPELINE_LAYERS_DIR"
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

  # style.json: the raster-dem source and the color-relief layer, under the
  # vector layer (order 5 < 10), with no source layer.
  run jq -e '
    .sources.cover == {type: "raster-dem", tileSize: 256, encoding: "custom",
      redFactor: (1 / 255), greenFactor: 0, blueFactor: 0, baseShift: 0,
      url: "pmtiles://cover.pmtiles"}
    and .sources.sample.type == "vector"
    and ([.layers[].id] == ["cover-raster", "sample-fill", "sample-outline"])
    and (.layers[0] | .type == "color-relief" and .source == "cover"
         and (has("source-layer") | not))' "$STYLE"
  [ "$status" -eq 0 ]
}

@test "the colour lives in the style: recolouring leaves the tiles as they were" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local archive="${PIPELINE_OUTPUT_DIR}/cover.pmtiles" x y before
  read -r x y < <(tile_at "$archive" 8)
  before=$(pmtiles tile "$archive" 8 "$x" "$y" | sha256sum)

  jq '.symbology.color = "#ff0000"' "${PIPELINE_ROOT}/tests/fixtures/raster.style.json" \
    >"${PIPELINE_LAYERS_DIR}/cover.style.json"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [ "$(pmtiles tile "$archive" 8 "$x" "$y" | sha256sum)" = "$before" ]
  run jq -r '.layers[0].paint["color-relief-color"][6]' "$STYLE"
  [ "$output" = "rgba(255, 0, 0, 1)" ]
}

@test "a bad raster display config fails before tiling and keeps the previous archive" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "${PIPELINE_OUTPUT_DIR}/cover.pmtiles")

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

  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/cover.pmtiles")" = "$before" ]
  assert_no_temp_files
}

@test "the raster shorthand on a vector layer is rejected" {
  cp "${PIPELINE_ROOT}/layers/sample.env" "$PIPELINE_LAYERS_DIR"
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
