#!/usr/bin/env bats
# The max zoom of a vector layer (ADR 0013): every processing preset passes
# tippecanoe's --simplify-only-low-zooms, so the pipeline alone generalises
# polygons there (lib/generalise.sh), on the synthetic island coverage from
# fixtures/make_islands.sh (generated here, not committed). Run in the test
# image with the other bats files.

load helpers

setup_file() {
  PIPELINE_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
  export PIPELINE_ROOT
  export ISLANDS_RAW="${BATS_FILE_TMPDIR}/raw"
  mkdir -p "$ISLANDS_RAW"
  "${PIPELINE_ROOT}/tests/fixtures/make_islands.sh" >"${ISLANDS_RAW}/islands.geojson"
}

setup() {
  RUN="${PIPELINE_ROOT}/bin/run.sh"
  export PIPELINE_INPUT_DIR=$ISLANDS_RAW
  export PIPELINE_OUTPUT_DIR="${BATS_TEST_TMPDIR}/tiles"
  export PIPELINE_LAYERS_DIR="${BATS_TEST_TMPDIR}/layers"
  mkdir -p "$PIPELINE_LAYERS_DIR"
  ARCHIVE="${PIPELINE_OUTPUT_DIR}/islands.pmtiles"
  BUILD="${PIPELINE_OUTPUT_DIR}/build.json"
}

# write_config [EXPR...]: the islands layer, z0 to z4 with the coverage
# profile, changed by any yq EXPRs. At z4 the zigzag shared border (0.005
# degrees either side of -99) is under a tile unit, so tippecanoe's
# simplification takes it out.
write_config() {
  layer_file "${PIPELINE_LAYERS_DIR}/islands.yaml" '.source.path = "islands.geojson"' \
    '.fields.keep = ["name"]' '.processing.maxzoom = 4' '.processing.profile = "coverage"' "$@"
}

# without_full_detail: put a tippecanoe on the PATH that runs the real one
# without --simplify-only-low-zooms, for this test.
without_full_detail() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  # shellcheck disable=SC2016 # the stub's own $@ and $a, as text.
  printf '%s\n' '#!/usr/bin/env bash' 'args=()' \
    'for a in "$@"; do [[ $a == --simplify-only-low-zooms ]] || args+=("$a"); done' \
    "exec $(command -v tippecanoe) \"\${args[@]}\"" >"${BATS_TEST_TMPDIR}/bin/tippecanoe"
  chmod +x "${BATS_TEST_TMPDIR}/bin/tippecanoe"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# generator_options: the tippecanoe options recorded in the archive.
generator_options() {
  pmtiles show --metadata "$ARCHIVE" | jq -r .generator_options
}

# vertices_at_zoom Z ID: vertices of feature ID at zoom Z of the archive (the
# fixture is in one tile at every zoom).
vertices_at_zoom() {
  ogr2ogr -f CSV /vsistdout/ -oo "ZOOM_LEVEL=$1" "$ARCHIVE" -dialect SQLITE \
    -sql "SELECT SUM(ST_NPoints(geometry)) AS n FROM islands WHERE mvt_id = $2" | tail -n 1
}

@test "every preset passes --simplify-only-low-zooms" {
  local profile
  for profile in coverage default points; do
    write_config ".processing.profile = \"${profile}\""
    run "$RUN" islands
    echo "$output"
    [ "$status" -eq 0 ]
    run generator_options
    [[ $output == *"--simplify-only-low-zooms"* ]]
    run jq -r '.layers[0].profile' "$BUILD"
    [ "$output" = "$profile" ]
  done
}

@test "the max zoom is simplified gently by the pipeline; 0 keeps full detail" {
  # Defaults: the pipeline simplifies z4 at 0.5 px.
  write_config
  run "$RUN" islands
  [ "$status" -eq 0 ]
  local gen_max gen_low
  gen_max=$(vertices_at_zoom 4 1)
  gen_low=$(vertices_at_zoom 3 1)

  # 0: z4 at full detail, as tippecanoe leaves it (--simplify-only-low-zooms).
  write_config '.processing.maxzoom_min_part_px = 0' '.processing.maxzoom_simplify_px = 0'
  run "$RUN" islands
  [ "$status" -eq 0 ]
  local full_max full_low
  full_max=$(vertices_at_zoom 4 1)
  full_low=$(vertices_at_zoom 3 1)

  # Without the flag tippecanoe would simplify z4 itself.
  without_full_detail
  run "$RUN" islands
  [ "$status" -eq 0 ]
  run generator_options
  [[ $output != *"--simplify-only-low-zooms"* ]]
  local simple_max
  simple_max=$(vertices_at_zoom 4 1)

  echo "z4: generalised $gen_max, full $full_max, tippecanoe $simple_max; z3: $gen_low, $full_low"
  # The zigzag border (101 vertices) stays at z4 only at full detail.
  ((full_max > gen_max + 50))
  ((full_max > simple_max + 50))
  # Lower zooms are generalised with their own settings either way.
  ((gen_low < 20 && full_low < 20))
}
