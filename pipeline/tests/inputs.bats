#!/usr/bin/env bats
# Input handling tests: shapefiles without .prj or .cpg, and zipped
# shapefiles. The shapefiles are made here with ogr2ogr from GeoJSON, so no
# binaries are committed. Run in the test image with the other bats files.

load helpers

setup() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  SAMPLE="${PIPELINE_ROOT}/tests/fixtures/sample.geojson"
  export PIPELINE_INPUT_DIR="${BATS_TEST_TMPDIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  mkdir -p "$PIPELINE_INPUT_DIR" "$PIPELINE_LAYERS_DIR"
}

# write_config LAYER INPUT [EXPR...]: a layer file for the sample fixture's
# attributes from INPUT, z0 to 4, changed by any yq EXPRs.
write_config() {
  local layer=$1 input=$2
  shift 2
  layer_file "${PIPELINE_LAYERS_DIR}/${layer}.yaml" ".source.path = \"${input}\"" \
    '.fields.keep = [{"NAME_EN": "name"}, "score"]' "$@"
}

# Decoded `name` of feature ID at z0 of LAYER.
name_of() {
  tippecanoe-decode "${PIPELINE_OUTPUT_DIR}/$1.pmtiles" 0 0 0 \
    | jq -r --argjson id "$2" '.features[].features[] | select(.id == $id) | .properties.name'
}

# The layer's bounds match the sample fixture's to 0.001 degrees.
assert_sample_bounds() {
  run jq -e --arg name "$1" '.layers[] | select(.name == $name) | .bounds as $b
    | [-125, 46, -66, 56] as $want
    | all(range(4); ($b[.] - $want[.]) | fabs < 0.001)' "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "$status" -eq 0 ]
}

@test "a shapefile without .prj needs source.srs, which reprojects it" {
  mkdir -p "${PIPELINE_INPUT_DIR}/lcc"
  ogr2ogr -f "ESRI Shapefile" -t_srs EPSG:3347 "${PIPELINE_INPUT_DIR}/lcc/sample.shp" "$SAMPLE"
  rm "${PIPELINE_INPUT_DIR}/lcc/sample.prj"

  write_config noprj lcc/sample.shp
  run "$RUN" noprj
  [ "$status" -eq 1 ]
  [[ $output == *"Use -s_srs to set one"* ]]
  [ ! -e "${PIPELINE_OUTPUT_DIR}/noprj.pmtiles" ]

  write_config noprj lcc/sample.shp '.source.srs = "EPSG:3347"'
  run "$RUN" noprj
  [ "$status" -eq 0 ]
  assert_sample_bounds noprj
  run jq -r '.layers[0].feature_count' "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "$output" = "15" ]
}

@test "source.encoding reads a shapefile without .cpg; fields.keep restores a cut name" {
  printf '%s\n' '{"type": "FeatureCollection", "features": [' \
    '{"type": "Feature", "properties": {"id": 1, "NAME_EN": "Érable à sucre", "score": 5, "description_long": "Forêt"},' \
    ' "geometry": {"type": "Polygon", "coordinates": [[[-80, 45], [-79, 45], [-79, 46], [-80, 46], [-80, 45]]]}}' \
    ']}' >"${BATS_TEST_TMPDIR}/latin.geojson"
  mkdir -p "${PIPELINE_INPUT_DIR}/latin"
  local shp="${PIPELINE_INPUT_DIR}/latin/latin.shp"
  ogr2ogr -f "ESRI Shapefile" -lco ENCODING=ISO-8859-1 "$shp" "${BATS_TEST_TMPDIR}/latin.geojson"
  # Shapefile cuts field names to 10 characters.
  run ogrinfo -so -al "$shp"
  [[ $output == *"descriptio: String"* ]]
  # Drop the encoding hints: the .cpg file and the DBF language driver byte.
  rm "${PIPELINE_INPUT_DIR}/latin/latin.cpg"
  printf '\0' | dd of="${PIPELINE_INPUT_DIR}/latin/latin.dbf" bs=1 seek=29 conv=notrunc status=none

  # Without source.encoding the Latin-1 bytes pass through as is, and
  # tippecanoe rejects them as invalid UTF-8.
  write_config latin latin/latin.shp
  run "$RUN" latin
  [ "$status" -eq 1 ]
  [[ $output == *"is not valid UTF-8"* ]]

  write_config latin latin/latin.shp '.source.encoding = "ISO-8859-1"' \
    '.fields.keep += [{"descriptio": "description"}]'
  run "$RUN" latin
  [ "$status" -eq 0 ]
  [ "$(name_of latin 1)" = "Érable à sucre" ]
  run bash -c "tippecanoe-decode '${PIPELINE_OUTPUT_DIR}/latin.pmtiles' 0 0 0 \
    | jq -r '.features[].features[0].properties.description'"
  [ "$output" = "Forêt" ]
}

@test "reads zipped shapefiles in place through /vsizip/" {
  # A .shp.zip, as GDAL writes it, and a plain .zip with the shapefile in a
  # folder, named by its path inside the zip.
  ogr2ogr -f "ESRI Shapefile" "${PIPELINE_INPUT_DIR}/sample.shp.zip" "$SAMPLE"
  mkdir -p "${BATS_TEST_TMPDIR}/bundle/shp"
  ogr2ogr -f "ESRI Shapefile" "${BATS_TEST_TMPDIR}/bundle/shp/sample.shp" "$SAMPLE"
  (cd "${BATS_TEST_TMPDIR}/bundle" && python3 -m zipfile -c "${PIPELINE_INPUT_DIR}/bundle.zip" shp)

  write_config shpzip sample.shp.zip
  write_config bundle bundle.zip/shp/sample.shp
  run "$RUN" shpzip bundle
  [ "$status" -eq 0 ]
  [[ $output == *"normalising ${PIPELINE_INPUT_DIR}/bundle.zip/shp/sample.shp"* ]]
  run jq -r '[.layers[] | "\(.name):\(.feature_count)"] | join(",")' "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "$output" = "bundle:15,shpzip:15" ]
  assert_sample_bounds bundle
  [ "$(name_of bundle 3)" = "Cedar" ]
}

@test "a missing zip is reported as a missing input" {
  write_config gone gone.zip/shp/sample.shp
  run "$RUN" gone
  [ "$status" -eq 1 ]
  [[ $output == *"input not found: ${PIPELINE_INPUT_DIR}/gone.zip"* ]]
}

@test "source.path: relative to the input dir, absolute, or a /vsi path, as given" {
  mkdir -p "${PIPELINE_INPUT_DIR}/sub" "${BATS_TEST_TMPDIR}/zip"
  cp "$SAMPLE" "${PIPELINE_INPUT_DIR}/sub/sample.geojson"
  cp "$SAMPLE" "${BATS_TEST_TMPDIR}/zip/sample.geojson"
  (cd "${BATS_TEST_TMPDIR}/zip" && python3 -m zipfile -c "${BATS_TEST_TMPDIR}/sample.zip" sample.geojson)

  write_config relative sub/sample.geojson
  write_config absolute "$SAMPLE"
  write_config vsi "/vsizip/${BATS_TEST_TMPDIR}/sample.zip/sample.geojson"
  run "$RUN" relative absolute vsi
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"normalising ${PIPELINE_INPUT_DIR}/sub/sample.geojson"* ]]
  [[ $output == *"normalising ${SAMPLE}"* ]]
  [[ $output == *"normalising /vsizip/${BATS_TEST_TMPDIR}/sample.zip/sample.geojson"* ]]

  # The manifest records a path under the input dir relative to it, and
  # any other as it is; a /vsi path has no size or time.
  run jq -r '.layers[] | "\(.name) \(.provenance.source.path) \(.provenance.source.bytes != null) \(.feature_count)"' \
    "${PIPELINE_OUTPUT_DIR}/manifest.json"
  [ "${lines[0]}" = "absolute ${SAMPLE} true 15" ]
  [ "${lines[1]}" = "relative sub/sample.geojson true 15" ]
  [ "${lines[2]}" = "vsi /vsizip/${BATS_TEST_TMPDIR}/sample.zip/sample.geojson false 15" ]
}
