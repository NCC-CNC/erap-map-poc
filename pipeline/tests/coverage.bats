#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR/..
# Coverage tile profile and drop guard tests, on the synthetic coverage from
# fixtures/make_coverage.sh (generated here, not committed). Run in the test
# image with the other bats files:
#   docker build --target test -t erap-pipeline-test pipeline
#   docker run --rm erap-pipeline-test

# Build the coverage layer once, with the coverage profile, for the read-only
# tests. Tests that change the config build their own copy.
setup_file() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  export PIPELINE_ROOT
  export COVERAGE_DIR="${BATS_FILE_TMPDIR}/coverage"
  mkdir -p "${COVERAGE_DIR}/raw" "${COVERAGE_DIR}/layers"
  "${PIPELINE_ROOT}/tests/fixtures/make_coverage.sh" >"${COVERAGE_DIR}/raw/coverage.geojson"
  write_coverage_config "${COVERAGE_DIR}/layers/coverage.env" 'LAYER_PROFILE=coverage'

  PIPELINE_INPUT_DIR="${COVERAGE_DIR}/raw" \
    PIPELINE_OUTPUT_DIR="${COVERAGE_DIR}/tiles" \
    PIPELINE_LAYERS_DIR="${COVERAGE_DIR}/layers" \
    "${PIPELINE_ROOT}/bin/run.sh" coverage >"${COVERAGE_DIR}/build.log" 2>&1

  # Per-feature sizes, measured the way the pipeline does.
  (
    # shellcheck source=lib/log.sh
    source "${PIPELINE_ROOT}/lib/log.sh"
    # shellcheck source=lib/normalise.sh
    source "${PIPELINE_ROOT}/lib/normalise.sh"
    # shellcheck source=lib/guard.sh
    source "${PIPELINE_ROOT}/lib/guard.sh"
    feature_sizes "${COVERAGE_DIR}/raw/coverage.geojson" id "${COVERAGE_DIR}/sizes.tsv"
  )
}

setup() {
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  ARCHIVE="${COVERAGE_DIR}/tiles/coverage.pmtiles"
  MANIFEST="${COVERAGE_DIR}/tiles/manifest.json"
  export PIPELINE_INPUT_DIR="${COVERAGE_DIR}/raw"
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  mkdir -p "$PIPELINE_LAYERS_DIR"
}

# write_coverage_config FILE [LINE...]: the coverage layer config, z0 to z6,
# plus any extra lines.
write_coverage_config() {
  local file=$1
  shift
  printf '%s\n' 'LAYER_INPUT=coverage.geojson' 'LAYER_FIELDS=(id kind)' \
    'LAYER_FEATURE_ID=id' 'LAYER_MIN_ZOOM=0' 'LAYER_MAX_ZOOM=6' "$@" >"$file"
}

# Distinct feature ids of one kind at zoom Z of ARCHIVE, one per line.
ids_at_zoom() {
  local archive=$1 z=$2 kind=$3
  ogr2ogr -f CSV /vsistdout/ -oo "ZOOM_LEVEL=${z}" "$archive" \
    -sql "SELECT DISTINCT mvt_id FROM coverage WHERE kind = '${kind}'" | tail -n +2
}

# coverage_gaps ARCHIVE: the gap check. For every zoom, decode every tile in
# integer tile coordinates, clip to the tile (the buffer is not drawn) and
# measure, with GDAL's SQLite dialect and SpatiaLite:
#   gap      the coverage's footprint in the tile (the fixture's outer
#            rectangle, -120..-100, 50..60) less the union of all polygons;
#   overlap  the polygons visible at that zoom (required, by the drop guard's
#            rule with the default 1 px) summed, less their union.
# Shared borders simplified identically leave no gap and no overlap. The
# only holes allowed are where polygons too small to see were reduced or
# dropped, so per zoom the gaps may add up to no more than the area of those
# polygons. Prints one line per zoom; returns 1 if any zoom fails.
coverage_gaps() {
  local archive=$1 sizes="${COVERAGE_DIR}/sizes.tsv" work="${BATS_TEST_TMPDIR}/gaps"
  mkdir -p "$work"
  local status=0 z x y
  for z in $(seq 0 6); do
    # Required ids at z as a JSON object, and the allowed gap in tile units
    # squared (4096 per tile side, so 16 x 16 per screen pixel).
    local k req allowed
    k=$(awk -v z="$z" 'BEGIN { printf "%.17g", (256 * 2 ^ z / 40075016.68557849) ^ 2 }')
    req=$(awk -F'\t' -v k="$k" '$2 * k >= 1 { printf "%s\"%s\": true", (n++ ? "," : "{"), $1 }
      END { print (n ? "}" : "{}") }' "$sizes")
    allowed=$(awk -F'\t' -v k="$k" '$2 * k < 1 { s += $2 * k * 256 } END { printf "%.3f", s }' "$sizes")

    local gap=0 overlap=0
    while read -r x y; do
      tippecanoe-decode -I "$archive" "$z" "$x" "$y" | jq --argjson req "$req" \
        '{type: "FeatureCollection", features: [.features[].features[]
          | .properties.req = (if $req[.id | tostring] then 1 else 0 end)]}' \
        >"${work}/t.geojson"
      local frame
      frame=$(awk -v z="$z" -v x="$x" -v y="$y" '
        function px(lon) { return ((lon + 180) / 360 * 2 ^ z - x) * 4096 }
        function py(lat,  r) { r = lat * 3.14159265358979 / 180
          return ((1 - log(sin(r) / cos(r) + 1 / cos(r)) / 3.14159265358979) / 2 * 2 ^ z - y) * 4096 }
        function c(v) { v = int(v + 0.5); return v < 0 ? 0 : (v > 4096 ? 4096 : v) }
        BEGIN { printf "%d, %d, %d, %d", c(px(-120)), c(py(60)), c(px(-100)), c(py(50)) }')
      local line
      line=$(ogr2ogr -f CSV /vsistdout/ "${work}/t.geojson" -dialect SQLite -sql "
        WITH c AS (SELECT req, ST_Intersection(geometry, BuildMbr(${frame})) AS g FROM t)
        SELECT ST_Area(BuildMbr(${frame})) - COALESCE((SELECT ST_Area(ST_Union(g)) FROM c), 0) AS gap,
          COALESCE((SELECT SUM(ST_Area(g)) - ST_Area(ST_Union(g)) FROM c WHERE req = 1), 0) AS overlap" \
        | tail -n 1)
      gap=$(awk -v a="$gap" -v b="${line%%,*}" 'BEGIN { printf "%.3f", a + b }')
      overlap=$(awk -v a="$overlap" -v b="${line##*,}" 'BEGIN { printf "%.3f", a + b }')
    done < <(tippecanoe-decode --stats "$archive" | jq -r --argjson z "$z" '.[] | select(.zoom == $z) | "\(.x) \(.y)"')

    local verdict=ok
    if ! awk -v g="$gap" -v a="$allowed" -v o="$overlap" 'BEGIN { exit !(g <= a + 1 && o < 1) }'; then
      verdict=FAIL
      status=1
    fi
    echo "z${z} gap=${gap} allowed=${allowed} overlap=${overlap} ${verdict}"
  done
  return "$status"
}

@test "coverage fixture is a valid coverage with large, medium and tiny polygons" {
  local input="${COVERAGE_DIR}/raw/coverage.geojson"
  # Deterministic: a second run gives the same file.
  run diff <("${PIPELINE_ROOT}/tests/fixtures/make_coverage.sh") "$input"
  [ "$status" -eq 0 ]

  # No gaps, overlaps or invalid geometries in the input itself.
  gdal vector check-coverage --quiet --maximum-gap-width 0.01 "$input" "${BATS_TEST_TMPDIR}/edges.geojson"
  run jq '.features | length' "${BATS_TEST_TMPDIR}/edges.geojson"
  [ "$output" = "0" ]
  gdal vector check-geometry --quiet "$input" "${BATS_TEST_TMPDIR}/invalid.geojson"
  run jq '.features | length' "${BATS_TEST_TMPDIR}/invalid.geojson"
  [ "$output" = "0" ]

  run jq -r '[.features[].properties.kind] | group_by(.) | map("\(.[0]):\(length)") | join(",")' "$input"
  [ "$output" = "large:18,medium:40,tiny:1000" ]
}

@test "coverage profile passes the shared-node and drop-smallest flags" {
  [ -s "$ARCHIVE" ]
  run bash -c "pmtiles show --metadata '$ARCHIVE' | jq -r .generator_options"
  [ "$status" -eq 0 ]
  [[ $output == *"--no-simplification-of-shared-nodes"* ]]
  [[ $output == *"--drop-smallest-as-needed"* ]]
  [[ $output == *"--read-parallel"* ]]
  [[ $output != *"--detect-shared-borders"* ]]
  [[ $output != *"--coalesce"* ]]

  run jq -r '.layers[0] | "\(.profile) \(.min_visible_px)"' "$MANIFEST"
  [ "$output" = "coverage 1" ]
}

@test "shared borders stay identical at every zoom: no gaps or overlaps" {
  run coverage_gaps "$ARCHIVE"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
}

@test "without --no-simplification-of-shared-nodes the gap check fails" {
  write_coverage_config "${PIPELINE_LAYERS_DIR}/coverage.env" \
    'LAYER_TIPPECANOE_FLAGS=(--drop-smallest-as-needed)'
  run "$RUN" coverage
  [ "$status" -eq 0 ]

  run coverage_gaps "${PIPELINE_OUTPUT_DIR}/coverage.pmtiles"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *FAIL* ]]
}

@test "every large feature is present at every zoom; tiny ones may be absent at low zooms" {
  local z
  for z in $(seq 0 6); do
    run ids_at_zoom "$ARCHIVE" "$z" large
    [ "${#lines[@]}" -eq 18 ]
  done

  # Tiny polygons are about 1/100 of a pixel at z0: tippecanoe's tiny polygon
  # reduction leaves only some of them, which the guard allows and logs.
  run ids_at_zoom "$ARCHIVE" 0 tiny
  [ "${#lines[@]}" -lt 1000 ]
  run grep -E 'z0: .* not present \(allowed\)' "${COVERAGE_DIR}/build.log"
  [ "$status" -eq 0 ]

  # From z4 every polygon covers at least a pixel, and all are there.
  for z in 4 5 6; do
    run ids_at_zoom "$ARCHIVE" "$z" tiny
    [ "${#lines[@]}" -eq 1000 ]
  done
}

@test "manifest records per-zoom stats from the drop guard" {
  run jq -e '.layers[0] as $l
    | ($l.zooms | length == 7)
    and ([$l.zooms[].zoom] == [0, 1, 2, 3, 4, 5, 6])
    and all($l.zooms[]; .input == 1058 and .required == .required_present
            and .present <= .input and .max_tile_bytes > 0)
    and ($l.zooms[0].required == 18)
    and all($l.zooms[2:][]; .present == 1058)
    and all($l.zooms[5:][]; .required == 1058)
    and ($l.max_tile_bytes == ([$l.zooms[].max_tile_bytes] | max))
    and ($l.feature_count == 1058)' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "drop guard fails the build when a large feature is dropped, keeping the old archive" {
  write_coverage_config "${PIPELINE_LAYERS_DIR}/coverage.env" 'LAYER_PROFILE=coverage'
  run "$RUN" coverage
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "${PIPELINE_OUTPUT_DIR}/coverage.pmtiles" "${PIPELINE_OUTPUT_DIR}/manifest.json")

  # A tile limit this small makes --drop-smallest-as-needed drop large
  # polygons too.
  echo 'LAYER_TIPPECANOE_FLAGS=(--maximum-tile-bytes=1500)' >>"${PIPELINE_LAYERS_DIR}/coverage.env"
  run "$RUN" coverage
  [ "$status" -eq 1 ]
  [[ $output == *"required feature(s) missing"* ]]
  [[ $output == *"drop guard: required features missing"* ]]
  [ "$(sha256sum "${PIPELINE_OUTPUT_DIR}/coverage.pmtiles" "${PIPELINE_OUTPUT_DIR}/manifest.json")" = "$before" ]
  run find "$PIPELINE_OUTPUT_DIR" -name '*.tmp*'
  [ -z "$output" ]
}

@test "LAYER_MIN_VISIBLE_PX=0 requires every polygon at every zoom" {
  # Tiny polygon reduction at z0 then trips the guard.
  write_coverage_config "${PIPELINE_LAYERS_DIR}/coverage.env" 'LAYER_PROFILE=coverage' \
    'LAYER_MIN_VISIBLE_PX=0'
  run "$RUN" coverage
  [ "$status" -eq 1 ]
  [[ $output == *"z0: "*" of 1058 required feature(s) missing"* ]]
}

@test "unknown LAYER_PROFILE is rejected" {
  write_coverage_config "${PIPELINE_LAYERS_DIR}/coverage.env" 'LAYER_PROFILE=nope'
  run "$RUN" coverage
  [ "$status" -eq 1 ]
  [[ $output == *"unknown LAYER_PROFILE 'nope'"* ]]
}
