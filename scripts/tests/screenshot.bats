#!/usr/bin/env bats
# Tests for scripts/screenshot.sh's options, with no Docker or browser: the
# script runs as a copy in a fake repo under BATS_TEST_TMPDIR, with stub
# docker and curl commands first on the PATH that log their arguments to
# $STUB_LOG. What the browser does with the settings is
# scripts/screenshot.cjs, checked here for syntax only. Run in the
# pipeline test image (it has bats and node), with the repo mounted read
# only:
#   docker build --target test -t erap-map-pipeline:test pipeline
#   docker run --rm -v "$repo":/repo:ro erap-map-pipeline:test /repo/scripts/tests
#
# Each @test runs in a subshell, so its exports stay local (SC2030, SC2031).
# shellcheck disable=SC2030,SC2031

setup() {
  SRC=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  REPO=$T/repo
  mkdir -p "$REPO/scripts" "$REPO/data/tiles" "$REPO/web"
  cp "$SRC/scripts/screenshot.sh" "$SRC/scripts/screenshot.cjs" "$REPO/scripts/"
  printf '{"layers": []}\n' >"$REPO/data/tiles/manifest.json"
  SHOT=$REPO/scripts/screenshot.sh

  export STUB_LOG=$T/calls.log
  : >"$STUB_LOG"
  STUB=$T/bin
  mkdir -p "$STUB"
  local cmd
  for cmd in docker curl; do
    cat >"$STUB/$cmd" <<EOF
#!/usr/bin/env bash
echo "$cmd \$*" >>"\$STUB_LOG"
exit 0
EOF
    chmod +x "$STUB/$cmd"
  done
  export PATH="$STUB:$PATH"
}

# playwright_run: the logged `docker run` of the Playwright container.
playwright_run() {
  grep -F 'docker run --rm --init' "$STUB_LOG"
}

@test "--help documents --click and --colour-by" {
  run "$SHOT" --help
  [ "$status" -eq 0 ]
  [[ $output == *"-c, --click"* ]]
  [[ $output == *"--colour-by LAYER=THEME"* ]]
}

@test "without the options, no click and no colour theme reach the browser" {
  run "$SHOT" --image test:img -b light 4/55/-100
  [ "$status" -eq 0 ]
  run playwright_run
  [ "$status" -eq 0 ]
  [[ $output == *"-e SHOT_CLICK= "* ]]
  [[ $output == *"-e SHOT_COLOUR_BY= "* ]]
  [[ $output == *"-e SHOT_VIEWS=4/55/-100 "* ]]
}

@test "--click and repeated --colour-by are passed to the browser" {
  run "$SHOT" --image test:img -b light --click --colour-by ecoregions=wtw \
    --colour-by sample=score_gradient 4/55/-100 6/50/-110
  [ "$status" -eq 0 ]
  run playwright_run
  [ "$status" -eq 0 ]
  [[ $output == *"-e SHOT_CLICK=1 "* ]]
  [[ $output == *"-e SHOT_COLOUR_BY=ecoregions=wtw sample=score_gradient "* ]]
  [[ $output == *"-e SHOT_VIEWS=4/55/-100 6/50/-110 "* ]]
}

@test "-c is --click" {
  run "$SHOT" --image test:img -b dark -c 4/55/-100
  [ "$status" -eq 0 ]
  run playwright_run
  [[ $output == *"-e SHOT_CLICK=1 "* ]]
}

@test "a bad --colour-by is a usage error, before any docker call" {
  for bad in ecoregions wtw =wtw 'ecoregions=' 'Eco=wtw' 'eco=w tw' 'eco=wtw;rm'; do
    : >"$STUB_LOG"
    run "$SHOT" --image test:img --colour-by "$bad" 4/55/-100
    [ "$status" -eq 2 ]
    [[ $output == *"bad --colour-by"* ]]
    [ ! -s "$STUB_LOG" ]
  done
  run "$SHOT" --image test:img 4/55/-100 --colour-by
  [ "$status" -eq 2 ]
  [[ $output == *"--colour-by needs a value"* ]]
}

@test "screenshot.cjs is valid JavaScript" {
  run node --check "$REPO/scripts/screenshot.cjs"
  [ "$status" -eq 0 ]
}
