#!/usr/bin/env bats
# Tests for scripts/publish-pages.sh, with no GitHub: the script runs as a
# copy in a fake repo under BATS_TEST_TMPDIR, with a stub gh first on the
# PATH that logs its arguments to $STUB_LOG. STUB_GH_AUTH=fail makes
# `gh auth status` fail; STUB_GH_RELEASE=missing makes the release not
# found; STUB_GH_ASSETS lists the release's files. Also checks that
# map.config.pages.json is valid for the committed layers and in step with
# the script. Run in the pipeline test image (it has bats, jq and node),
# with the repo mounted read only:
#   docker build --target test -t erap-map-pipeline:test pipeline
#   docker run --rm -v "$repo":/repo:ro erap-map-pipeline:test /repo/scripts/tests
#
# Each @test runs in a subshell, so its exports stay local (SC2030, SC2031).
# shellcheck disable=SC2030,SC2031

setup() {
  SRC=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  REPO=$T/repo
  PAGES=$REPO/data/pages
  mkdir -p "$REPO/scripts" "$REPO/data/tiles" "$REPO/data/raw" "$PAGES"
  cp "$SRC/scripts/publish-pages.sh" "$REPO/scripts/"
  PUBLISH=$REPO/scripts/publish-pages.sh

  export STUB_LOG=$T/calls.log
  : >"$STUB_LOG"
  STUB=$T/bin
  mkdir -p "$STUB"
  cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
case "$1 $2" in
  "auth status") [[ ${STUB_GH_AUTH:-ok} == ok ]] || { echo "not logged in" >&2; exit 1; } ;;
  "repo view") echo "owner/repo" ;;
  "release view")
    [[ ${STUB_GH_RELEASE:-found} == found ]] || { echo "release not found" >&2; exit 1; }
    if [[ $* == *"--json assets"* ]]; then
      for a in ${STUB_GH_ASSETS:-}; do echo "$a"; done
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
}

# pages_build [DIR]: a Pages build in DIR (default data/pages) as the
# pipeline writes it: manifest.json (by jq, as pipeline/lib/manifest.sh
# does), style.json and the archives, plus files that are not published.
pages_build() {
  local dir=${1:-$PAGES}
  mkdir -p "$dir"
  jq -n '{updated_at: "2026-11-16T00:00:00Z", map: {center: [-96, 60], zoom: 3},
    layers: [
      {name: "forest", file: "forest.cog.tif", type: "raster",
       display: {title: "Forest", layers: [{id: "raster", paint: {}}]},
       provenance: {origin: "committed", source: {path: "Forest.tif", bytes: 1},
                    overrides: {env: {LAYER_MAX_ZOOM: 10}}}},
      {name: "protected_areas", file: "protected_areas.pmtiles", type: "vector",
       rules: null,
       provenance: {origin: "committed",
                    source: {path: "ProtectedConservedArea_2025.gdb", bytes: 2},
                    overrides: {input: "ProtectedConservedArea_2025.gdb"}}},
      {name: "ecoregions", file: "ecoregions.pmtiles", type: "vector",
       rules: {file: "/opt/pipeline/layers/ecoregions.rules.json"},
       provenance: {origin: "committed", source: {path: "eco.gdb"}, overrides: null}}
    ]}' >"$dir/manifest.json"
  printf '{"version": 8}\n' >"$dir/style.json"
  printf 'cog' >"$dir/forest.cog.tif"
  printf 'pa' >"$dir/protected_areas.pmtiles"
  printf 'eco' >"$dir/ecoregions.pmtiles"
  : >"$dir/.gitkeep"
  printf 'old' >"$dir/.forest.1.tmp.cog.tif"
  printf 'x' >"$dir/notes.txt"
}

# set_entry NAME JQ: change NAME's manifest entry with a jq update.
set_entry() {
  local m=$PAGES/manifest.json
  jq --arg n "$1" "(.layers[] | select(.name == \$n)) |= ($2)" "$m" >"$m.new"
  mv "$m.new" "$m"
}

# changes: the logged gh calls that change something on GitHub.
changes() {
  grep -E '^gh (release (create|upload|delete-asset)|workflow run)' "$STUB_LOG" || true
}

@test "--help documents the options and the checks" {
  run "$PUBLISH" --help
  [ "$status" -eq 0 ]
  [[ $output == *"-n, --dry-run"* ]]
  [[ $output == *"--no-deploy"* ]]
  [[ $output == *"1 GB"* ]]
  [[ $output == *"REQUIRED_SOURCES"* ]]
}

@test "usage errors exit 2" {
  run "$PUBLISH" --bogus
  [ "$status" -eq 2 ]
  run "$PUBLISH" --tag
  [ "$status" -eq 2 ]
  run "$PUBLISH" --repo nope
  [ "$status" -eq 2 ]
  run "$PUBLISH" a b
  [ "$status" -eq 2 ]
}

@test "dry run: checks, lists the plan and changes nothing" {
  pages_build
  export STUB_GH_ASSETS="manifest.json style.json old_layer.pmtiles"
  run "$PUBLISH" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"5 files"* ]]
  [[ $output == *"upload manifest.json"* ]]
  [[ $output == *"upload style.json"* ]]
  [[ $output == *"upload forest.cog.tif"* ]]
  [[ $output == *"upload protected_areas.pmtiles"* ]]
  [[ $output == *"upload ecoregions.pmtiles"* ]]
  [[ $output == *"remove old_layer.pmtiles"* ]]
  [[ $output == *"dry run: nothing was changed (release pages-data in owner/repo)"* ]]
  [[ $output != *".gitkeep"* ]]
  [[ $output != *"tmp.cog.tif"* ]]
  [[ $output != *"notes.txt"* ]]
  [ -z "$(changes)" ]
}

@test "publishes: creates the release, uploads only the build, removes stale files, runs the workflow" {
  pages_build
  export STUB_GH_RELEASE=missing
  run "$PUBLISH"
  [ "$status" -eq 0 ]
  run changes
  [ "${lines[0]}" = "gh release create pages-data --repo owner/repo --latest=false --title GitHub Pages data --notes Map data for the GitHub Pages copy of the map (ADR 0014), uploaded by scripts/publish-pages.sh. Not a software release." ]
  [ "${lines[1]}" = "gh release upload pages-data manifest.json style.json forest.cog.tif protected_areas.pmtiles ecoregions.pmtiles --repo owner/repo --clobber" ]
  [ "${lines[2]}" = "gh workflow run pages.yml --repo owner/repo --ref main" ]
  [ "${#lines[@]}" -eq 3 ]

  # An existing release: no create; files no longer built are removed.
  : >"$STUB_LOG"
  export STUB_GH_RELEASE=found STUB_GH_ASSETS="forest.cog.tif old_layer.pmtiles"
  run "$PUBLISH" --repo other/repo --tag demo --no-deploy
  [ "$status" -eq 0 ]
  [[ $output == *"not deployed (--no-deploy)"* ]]
  run changes
  [ "${lines[0]}" = "gh release upload demo manifest.json style.json forest.cog.tif protected_areas.pmtiles ecoregions.pmtiles --repo other/repo --clobber" ]
  [ "${lines[1]}" = "gh release delete-asset demo old_layer.pmtiles --repo other/repo --yes" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "fails clearly when gh is not signed in, before any change" {
  pages_build
  export STUB_GH_AUTH=fail
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"gh is not signed in: run gh auth login"* ]]
  run "$PUBLISH"
  [ "$status" -eq 1 ]
  [ -z "$(changes)" ]
}

@test "never publishes data/tiles/ or data/raw/" {
  pages_build "$REPO/data/tiles"
  pages_build "$REPO/data/raw/copy"
  run "$PUBLISH" --dry-run "$REPO/data/tiles"
  [ "$status" -eq 1 ]
  [[ $output == *"never data/tiles/ or data/raw/"* ]]
  run "$PUBLISH" "$REPO/data/tiles/"
  [ "$status" -eq 1 ]
  run "$PUBLISH" "$REPO/data/raw/copy"
  [ "$status" -eq 1 ]
  [[ $output == *"never data/tiles/ or data/raw/"* ]]
  # Through a link too.
  ln -s "$REPO/data/tiles" "$T/link"
  run "$PUBLISH" "$T/link"
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_LOG" ]
}

@test "refuses a missing folder, manifest, style or archive" {
  rm -rf "$PAGES"
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"build it first with docker compose run --rm pipeline-pages"* ]]

  pages_build
  rm "$PAGES/style.json"
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"no style.json"* ]]

  pages_build
  rm "$PAGES/ecoregions.pmtiles"
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"ecoregions: archive ecoregions.pmtiles not found"* ]]
  [[ $output == *"nothing was published"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "refuses protected areas from any other source, or without them" {
  pages_build
  set_entry protected_areas '.provenance.source.path = "protected_areas.gdb"'
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"protected_areas: built from 'protected_areas.gdb', not ProtectedConservedArea_2025.gdb"* ]]

  pages_build
  set_entry protected_areas 'del(.provenance)'
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"protected_areas: built from '', not ProtectedConservedArea_2025.gdb"* ]]

  pages_build
  jq '.layers |= map(select(.name != "protected_areas"))' "$PAGES/manifest.json" >"$T/m.json"
  mv "$T/m.json" "$PAGES/manifest.json"
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"protected_areas: not in the manifest"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "refuses local-only layers from a map config" {
  pages_build
  set_entry forest '.provenance.origin = "local"'
  set_entry ecoregions '.provenance.origin = "config"'
  run "$PUBLISH" --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"forest: not a committed layer (origin 'local')"* ]]
  [[ $output == *"ecoregions: not a committed layer (origin 'config')"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "fails over 1 GB and warns over 800 MB" {
  pages_build
  truncate -s 850000000 "$PAGES/forest.cog.tif"
  run "$PUBLISH" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"warning: the files total 850.0 MB"* ]]

  : >"$STUB_LOG"
  truncate -s 1100000000 "$PAGES/forest.cog.tif"
  run "$PUBLISH"
  [ "$status" -eq 1 ]
  [[ $output == *"over the 1 GB GitHub Pages limit"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "map.config.pages.json is valid for the committed layers and in step with the script" {
  # The pipeline's own check and resolution (bin/run.sh runs the same).
  run node /opt/pipeline/style/cli.mjs layers "$SRC/map.config.pages.json" "$SRC/pipeline/layers" "$T/resolved"
  [ "$status" -eq 0 ]
  run jq -r '.layers[] | select(.enabled | not) | .name' "$T/resolved/layers.json"
  [ -z "$output" ]
  # No local-only layers: committed ones only.
  run jq -r '[.layers[].origin] | unique | join(",")' "$T/resolved/layers.json"
  [ "$output" = committed ]
  # Rasters at max zoom 10.
  run jq -r '.overrides | [.forest.env.LAYER_MAX_ZOOM, .agriculture.env.LAYER_MAX_ZOOM] | join(",")' \
    "$SRC/map.config.pages.json"
  [ "$output" = "10,10" ]
  # The protected areas input is the required one, and the script checks it.
  run jq -r '.overrides.protected_areas.input == .requiredInputs.protected_areas' "$SRC/map.config.pages.json"
  [ "$output" = true ]
  local want got
  want=$(jq -r '.requiredInputs | to_entries[] | "\(.key)=\(.value)"' "$SRC/map.config.pages.json" | sort)
  got=$(bash -c "source <(sed -n '/^REQUIRED_SOURCES=(/,/^)/p' '$SRC/scripts/publish-pages.sh'); printf '%s\n' \"\${REQUIRED_SOURCES[@]}\"" | sort)
  [ -n "$want" ]
  [ "$want" = "$got" ]
}
