#!/usr/bin/env bats
# Layer files and map configs (design note 04): every committed
# <layer>.yaml validates against schema/layer.schema.json, and broken
# files fail. jv validates, yq makes the broken copies. The repo's map
# configs (map.pages.yaml, map.config.example.yaml) are checked in CI
# against schema/map.schema.json; here, made-up ones.

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  LAYER_SCHEMA="${PIPELINE_ROOT}/schema/layer.schema.json"
  MAP_SCHEMA="${PIPELINE_ROOT}/schema/map.schema.json"
  ECOREGIONS="${PIPELINE_ROOT}/layers/ecoregions.yaml"
  FOREST="${PIPELINE_ROOT}/layers/forest.yaml"
  SAMPLE="${PIPELINE_ROOT}/tests/layers/sample.yaml"
}

# broken SCHEMA FILE EXPR MESSAGE: FILE changed by the yq EXPR must fail
# SCHEMA, with MESSAGE in jv's output.
broken() {
  local schema=$1 file=$2 expr=$3 message=$4
  local copy="${BATS_TEST_TMPDIR}/broken.yaml"
  yq "$expr" "$file" >"$copy"
  run jv "$schema" "$copy"
  [ "$status" -ne 0 ]
  [[ $output == *"$message"* ]] || {
    echo "expected '$message' in:" >&2
    echo "$output" >&2
    return 1
  }
}

# valid FILE EXPR: run jv on FILE changed by the yq EXPR.
valid() {
  local copy="${BATS_TEST_TMPDIR}/changed.yaml"
  yq "$2" "$1" >"$copy"
  run jv "$LAYER_SCHEMA" "$copy"
}

# map_config YAML: write a map config, print its path.
map_config() {
  printf '%s\n' "$1" >"${BATS_TEST_TMPDIR}/map.yaml"
  echo "${BATS_TEST_TMPDIR}/map.yaml"
}

@test "the tools are installed" {
  run yq --version
  [ "$status" -eq 0 ]
  run jv --version
  [ "$status" -eq 0 ]
}

@test "every committed and test layer file, and the fixtures, are valid" {
  run jv "$LAYER_SCHEMA" "${PIPELINE_ROOT}"/layers/*.yaml "${PIPELINE_ROOT}"/tests/layers/*.yaml \
    "${PIPELINE_ROOT}"/tests/fixtures/*.yaml
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a layer file needs a title, a source, processing and display" {
  broken "$LAYER_SCHEMA" "$SAMPLE" 'del(.title)' "missing property 'title'"
  broken "$LAYER_SCHEMA" "$SAMPLE" 'del(.source.path)' "missing property 'path'"
  broken "$LAYER_SCHEMA" "$SAMPLE" 'del(.processing.maxzoom)' "missing property 'maxzoom'"
  broken "$LAYER_SCHEMA" "$SAMPLE" 'del(.display.layers)' "missing property 'layers'"
}

@test "unknown keys fail" {
  broken "$LAYER_SCHEMA" "$SAMPLE" '.colour = "red"' "additional properties 'colour' not allowed"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.processing.max_zoom = 8' "additional properties 'max_zoom' not allowed"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.layers[0].colour = "red"' "additional properties 'colour' not allowed"
}

@test "a vector layer needs a feature id" {
  broken "$LAYER_SCHEMA" "$SAMPLE" 'del(.source.id)' "missing property 'id'"
}

@test "an unknown profile fails" {
  broken "$LAYER_SCHEMA" "$SAMPLE" '.processing.profile = "fast"' "processing/profile"
}

@test "generalisation settings need a polygon profile, coverage or default" {
  local points="${PIPELINE_ROOT}/tests/layers/sample_points.yaml"
  broken "$LAYER_SCHEMA" "$points" '.processing.min_part_px = 2' "processing/min_part_px"
  broken "$LAYER_SCHEMA" "$points" '.processing.maxzoom_simplify_px = 0' "processing/maxzoom_simplify_px"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.processing.maxzoom_min_part_px = -1' "processing/maxzoom_min_part_px"
  # The same settings are fine on the coverage and default layers.
  run jv "$LAYER_SCHEMA" "$ECOREGIONS"
  [ "$status" -eq 0 ]
  valid "$SAMPLE" '.processing.min_part_px = 2 | .processing.maxzoom_min_part_px = 0 | .processing.maxzoom_simplify_px = 0'
  [ "$status" -eq 0 ]
}

@test "a raster layer has no fields, pop-up or vector settings" {
  broken "$LAYER_SCHEMA" "$FOREST" '.fields.keep = ["a"]' "/fields"
  broken "$LAYER_SCHEMA" "$FOREST" '.display.popup = {"title": "{a}", "sections": [{"description": "a"}]}' "display/popup"
  broken "$LAYER_SCHEMA" "$FOREST" '.processing.min_visible_px = 4' "processing/min_visible_px"
  broken "$LAYER_SCHEMA" "$FOREST" '.processing.maxzoom = 15' "processing/maxzoom"
  broken "$LAYER_SCHEMA" "$FOREST" '.processing.grey_levels = 8' "additional properties 'grey_levels'"
}

@test "style layers have no source and a short id" {
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.layers[0].source = "sample"' "display/layers/0"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.layers[0]."source-layer" = "sample"' "display/layers/0"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.layers[0].id = "-fill"' "display/layers/0/id"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.layers[0].type = "polygon"' "display/layers/0/type"
}

@test "one pop-up: small with one section, or a dialog of headed sections" {
  local dialog="${PIPELINE_ROOT}/tests/fixtures/sample_modal.yaml"
  # The old modal key and pop-up shape are gone.
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.modal = .display.popup' "additional properties 'modal' not allowed"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.stats = []' "additional properties 'stats' not allowed"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.title = {"attribute": "name"}' "display/popup/title"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.size = "large"' "display/popup/size"
  # A small pop-up: one section, no layout or tab.
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.sections += [{"description": "x"}]' "display/popup/sections"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.layout = "tabs"' "display/popup/layout"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.sections[0].tab = "x"' "display/popup/sections/0/tab"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.sections[0] = {"heading": "x"}' "display/popup/sections/0"
  # A dialog: every section has a heading.
  broken "$LAYER_SCHEMA" "$dialog" 'del(.display.popup.sections[1].heading)' "missing property 'heading'"
  broken "$LAYER_SCHEMA" "$dialog" '.display.popup.layout = "pages"' "display/popup/layout"
  # Charts: bar, line, pie, doughnut.
  broken "$LAYER_SCHEMA" "$SAMPLE" '.display.popup.sections[0].blocks[1].chart = "area"' "chart"
  valid "$SAMPLE" '.display.popup.sections[0].blocks[1].chart = "line"'
  [ "$status" -eq 0 ]
}

@test "number formats: number, integer and percent, units in suffix" {
  local at='.display.popup.sections[0].blocks[0].items[1].format'
  for preset in hectares km count; do
    broken "$LAYER_SCHEMA" "$SAMPLE" "${at} = \"${preset}\"" "format"
    broken "$LAYER_SCHEMA" "$SAMPLE" "${at} = {\"preset\": \"${preset}\"}" "format"
  done
  for format in '"number"' '"integer"' '"percent"' '{"preset": "integer", "suffix": "ha"}' '{"decimals": 1, "suffix": "km"}'; do
    valid "$SAMPLE" "${at} = ${format}"
    [ "$status" -eq 0 ]
  done
}

@test "themes: the first draws the layers as they are, the others set paint" {
  broken "$LAYER_SCHEMA" "$ECOREGIONS" '.display.themes[0].paint = {"fill": {"fill-color": "red"}}' "display/themes/0"
  broken "$LAYER_SCHEMA" "$ECOREGIONS" 'del(.display.themes[1].paint)' "display/themes/1"
  broken "$LAYER_SCHEMA" "$ECOREGIONS" '.display.legend = .display.themes[0].legend' "display/legend"
}

@test "fields.keep lists names, or one-key maps that rename" {
  local copy="${BATS_TEST_TMPDIR}/keep.yaml"
  yq '.fields.keep = ["area_ha", {"NAME_EN": "name"}, {"Score": "score"}]' "$SAMPLE" >"$copy"
  run jv "$LAYER_SCHEMA" "$copy"
  echo "$output"
  [ "$status" -eq 0 ]
  # A two-key item, a bad output name, a bad plain name, the old map form.
  broken "$LAYER_SCHEMA" "$SAMPLE" '.fields.keep[0] = {"NAME_EN": "name", "score": "score"}' "maxProperties"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.fields.keep[0] = {"NAME_EN": "Name"}' "'Name' does not match pattern"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.fields.keep[0] = "NAME_EN"' "'NAME_EN' does not match pattern"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.fields.keep = {"NAME_EN": "name"}' "want array"
}

@test "calculated field names are lower case" {
  broken "$LAYER_SCHEMA" "$SAMPLE" '.fields.calculated.Bad = "1"' "'Bad' does not match pattern"
}

@test "processing.tippecanoe: extra arguments starting with --, vector only" {
  local copy="${BATS_TEST_TMPDIR}/extra.yaml"
  yq '.processing.tippecanoe = ["--drop-densest-as-needed", "--buffer=8"]' "$SAMPLE" >"$copy"
  run jv "$LAYER_SCHEMA" "$copy"
  echo "$output"
  [ "$status" -eq 0 ]
  broken "$LAYER_SCHEMA" "$SAMPLE" '.processing.tippecanoe = ["drop-densest-as-needed"]' "processing/tippecanoe/0"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.processing.tippecanoe = ["-z", "8"]' "processing/tippecanoe/0"
  broken "$LAYER_SCHEMA" "$SAMPLE" '.processing.tippecanoe = "--buffer=8"' "processing/tippecanoe"
  broken "$LAYER_SCHEMA" "$FOREST" '.processing.tippecanoe = ["--buffer=8"]' "processing/tippecanoe"
}

@test "a valid map config passes" {
  local file
  file=$(map_config '
view: { center: [-96, 60], zoom: 3 }
basemap: dark
layers: [ecoregions, forest]
overrides:
  forest: { processing: { maxzoom: 10 } }
  protected_areas: { source: { path: other.gdb, layer: other } }
require: [protected_areas]')
  run jv "$MAP_SCHEMA" "$file"
  echo "$output"
  [ "$status" -eq 0 ]
  # Every key is optional.
  file=$(map_config '{}')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -eq 0 ]
}

@test "a map config cannot override display or fields" {
  local file
  file=$(map_config 'overrides: { forest: { display: { layers: [] } } }')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -ne 0 ]
  [[ $output == *"additional properties 'display' not allowed"* ]]
  file=$(map_config 'overrides: { ecoregions: { fields: { keep: [name] } } }')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -ne 0 ]
}

@test "a map config in the old format or with bad values fails" {
  local file
  file=$(map_config 'map: { center: [-96, 60], zoom: 3, basemap: light }')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -ne 0 ]
  [[ $output == *"additional properties 'map' not allowed"* ]]
  file=$(map_config 'basemap: satellite')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -ne 0 ]
  file=$(map_config 'overrides: { forest: { processing: { maxzoom: ten } } }')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -ne 0 ]
  file=$(map_config 'layers: [Forest]')
  run jv "$MAP_SCHEMA" "$file"
  [ "$status" -ne 0 ]
}
