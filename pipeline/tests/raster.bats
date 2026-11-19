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
    and (.metadata.IMAGE_STRUCTURE | has("PREDICTOR") | not)
    and .metadata.TILING_SCHEME == {NAME: "GoogleMapsCompatible", ZOOM_LEVEL: "8"}
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
      and .resampling == "near" and (has("max_zoom_values") | not) and (has("grey_levels") | not)
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

@test "--remove deletes a raster layer's COG" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  run "$RUN" --remove cover
  [ "$status" -eq 0 ]
  [ ! -e "$COG" ]
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

@test "prepare: a changed source or source.nodata is prepared again, in place" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local cache="${PIPELINE_WORK_DIR}/raster" first
  first=$(jq -c . "${cache}/cover.json")

  # Same path, new modification time.
  touch -d '2020-01-01' "${PIPELINE_INPUT_DIR}/cover.tif"
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"preparing"* ]]
  local second
  second=$(jq -c . "${cache}/cover.json")
  [ "$second" != "$first" ]
  [ "$(find "$cache" -type f | sort | paste -sd' ')" = "${cache}/cover.json ${cache}/cover.tif" ]

  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.source.nodata = 255'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"preparing"* ]]
  [ "$(jq -r .nodata "${cache}/cover.json")" = 255 ]
  [ "$(find "$cache" -name '*.tif' | wc -l)" -eq 1 ]
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

@test "raster_method: mode when the max zoom's pixel is coarser than the source's" {
  # A 30 m source at about 46 N is about 43 m in EPSG:3857: z12 is 38.2 m,
  # z11 76.4 m.
  run raster_fn raster_method 43.2 12
  [ "$status" -eq 0 ]
  [ "$output" = near ]
  run raster_fn raster_method 43.2 11
  [ "$output" = mode ]
}

@test "raster_extent: GDAL's extent widened to whole tiles at the max zoom" {
  local tile=156543.03392804097 # z8: 40075016.68557849 / 2^8
  run raster_fn raster_extent 8 -9000000.5 5000000.5 -8000000.5 6000000.5
  [ "$status" -eq 0 ]
  read -r x0 y0 x1 y1 <<<"$output"
  awk -v t="$tile" -v x0="$x0" -v y0="$y0" -v x1="$x1" -v y1="$y1" 'BEGIN {
    o = 20037508.342789244
    for (i = 1; i <= 4; i++) {
      v = (i == 1 ? x0 + o : i == 2 ? o - y0 : i == 3 ? x1 + o : o - y1) / t
      if (v - int(v + 0.5) > 1e-6 || int(v + 0.5) - v > 1e-6) exit 1
    }
    exit !(x0 <= -9000000.5 && x0 > -9000000.5 - t && y0 <= 5000000.5 && y0 > 5000000.5 - t \
      && x1 >= -8000000.5 && x1 < -8000000.5 + t && y1 >= 6000000.5 && y1 < 6000000.5 + t)
  }'
  # Already on whole tiles: unchanged.
  run raster_fn raster_extent 8 "$x0" "$y0" "$x1" "$y1"
  [ "$output" = "$x0 $y0 $x1 $y1" ]
}

@test "the source's pixel and extent come from GDAL's suggested Web Mercator grid" {
  "$MAKE" byte "${BATS_TEST_TMPDIR}/b.tif"
  run raster_fn raster_suggested "${BATS_TEST_TMPDIR}/b.tif" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  read -r res x0 y0 x1 y1 <<<"$output"
  # 1 km cells near 52 N: about 1.6 km in EPSG:3857; around Winnipeg.
  awk -v r="$res" -v x0="$x0" -v x1="$x1" -v y0="$y0" -v y1="$y1" \
    'BEGIN { exit !(r > 1400 && r < 1800 && x0 < x1 && y0 < y1 && x0 > -11000000 && x1 < -9500000) }'
  [ ! -e "${BATS_TEST_TMPDIR}/suggested.vrt" ]
}

@test "a max zoom coarser than the source: mode, binary, overviews close to a finer build's" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"resampling near"* ]]
  [ "$(jq -r '.layers[0].resampling' "$BUILD")" = near ]
  # z5 in the z8 build: three overviews down.
  local overview
  overview=$(level_sum "$COG" 3)

  # z7 (about 1.2 km in EPSG:3857) is finer than the source (about 1.6 km),
  # z6 (about 2.4 km) coarser.
  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.maxzoom = 7'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"resampling near"* ]]
  set_layer "${PIPELINE_LAYERS_DIR}/cover.yaml" '.processing.maxzoom = 6'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  [[ $output == *"resampling mode"* ]]
  [ "$(jq -r '.layers[0].resampling' "$BUILD")" = mode ]
  # Only 0 and 255 at the max zoom ...
  run level_values "$COG" 0
  [ "$status" -eq 0 ]
  [ "$(sort -nu <<<"$output" | paste -sd' ')" = "0 255" ]
  # ... and the first overview has about the share covered of the z8
  # build's z5 overview, within 5%.
  local coarse
  coarse=$(level_sum "$COG" 1)
  awk -v a="$coarse" -v b="$overview" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= b * 0.05) }'
}

@test "mode: the max zoom is 255 where most of the pixel is covered" {
  raster_layer cover byte '.processing.maxzoom = 6'
  run "$RUN" cover
  [ "$status" -eq 0 ]
  # The share covered on the same grid, by GDAL's average.
  local prepared="${PIPELINE_WORK_DIR}/raster/cover.tif" ref="${BATS_TEST_TMPDIR}/ref.tif" grid
  grid=$(raster_fn raster_suggested "$prepared" "$BATS_TEST_TMPDIR")
  read -r -a grid <<<"$grid"
  # shellcheck disable=SC2046 # four numbers.
  raster_fn raster_warp "$prepared" 6 average "$ref" $(raster_fn raster_extent 6 "${grid[@]:1}")

  run paste <(gdal_translate -q -of XYZ "$ref" /vsistdout/ | awk '{ print $3 }') \
    <(gdal_translate -q -of XYZ "$COG" /vsistdout/ | awk '{ print $3 }')
  [ "$status" -eq 0 ]
  # Clearly more or less than half covered: 255 or 0. Shares near half may
  # go either way.
  run awk '($1 > 140 && $2 != 255) || ($1 < 115 && $2 != 0) { bad++ }
    $1 > 0 && $1 < 255 { partial++ } END { printf "%d %d %d\n", bad, partial, NR }' <<<"$output"
  read -r bad partial count <<<"$output"
  ((bad == 0 && partial > 100 && count > 1000))
}

@test "the COG driver does not warp again: the warped raster is on its tiling scheme" {
  raster_layer cover byte
  run "$RUN" cover
  [ "$status" -eq 0 ]
  local prepared="${PIPELINE_WORK_DIR}/raster/cover.tif" warped="${BATS_TEST_TMPDIR}/w.tif" grid
  grid=$(raster_fn raster_suggested "$prepared" "$BATS_TEST_TMPDIR")
  read -r -a grid <<<"$grid"
  # shellcheck disable=SC2046 # four numbers.
  raster_fn raster_warp "$prepared" 8 near "$warped" $(raster_fn raster_extent 8 "${grid[@]:1}")
  run env CPL_DEBUG=COG bash -c "source '${PIPELINE_ROOT}/lib/log.sh' &&
    source '${PIPELINE_ROOT}/lib/raster.sh' &&
    raster_cog '$warped' 8 5 '${BATS_TEST_TMPDIR}/c.cog.tif' '$BATS_TEST_TMPDIR'"
  [ "$status" -eq 0 ]
  [[ $output == *"Skipping reprojection step"* ]]
  [ "$(sha256sum <"${BATS_TEST_TMPDIR}/c.cog.tif")" = "$(sha256sum <"$COG")" ]
}
