#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Pipeline entry point: build tiles (vector tiles in a .pmtiles archive, or
# one COG for a raster layer, ADR 0010) for every enabled layer, or only the layers named on the command line. Each
# layer is <layer>.env (processing; LAYER_TYPE picks vector or raster) plus
# <layer>.style.json (display, ADR 0007; rasters, ADR 0008), committed in
# pipeline/layers/. A local map config (ADR 0009; PIPELINE_MAP_CONFIG,
# map.config.json at the repo root under compose) can select the layers,
# override their settings and display, add local-only layers and set the
# map's opening view; without one every committed layer is built as it is.
#
# Usage: run.sh [-h|--help] [layer ...]
#        run.sh --status [--json] [layer ...]
#        run.sh --style-only [layer ...]
#        run.sh --remove layer ...
#
#   (no option)  build the named layers, or every enabled layer. With no
#                names, a layer whose source data is not found is skipped
#                with a warning (the run fails only if nothing could be
#                built); a named layer with no source data fails.
#   --style-only update the named layers' display from their .style.json
#                (with the map config's display overrides), or every built
#                and enabled layer's, without re-tiling: check each config,
#                replace the display block of its manifest.json entry (the
#                build report is kept) and rewrite style.json. For a display
#                change (colours, legend, pop-up, title, order, visibility)
#                of a vector or raster layer, or a change to the map
#                config's layer selection or map view. A config with
#                `breaks` re-reads the source data, but not the tiles.
#   --status     list every configured or built layer (or the named ones)
#                with its state: current, stale (the .env, the map config's
#                input or env, or the source data changed since the build),
#                restyle (only the display config changed: --style-only is
#                enough), not built, source missing (a full build skips it),
#                invalid (cannot be built as configured), disabled (left
#                out by the map config) or orphan (built, config gone), plus
#                build time, archive size, zooms, feature count (size in
#                pixels for a raster layer) and largest tile. Read only.
#                --list is the same.
#   --json       with --status: print JSON instead of a table.
#   --remove     delete the named layers' archives and manifest entries
#                and rewrite style.json. The configs are not touched: delete
#                them first (git rm, or from the map config), or the next
#                full build makes the layer again.
#
# Environment (defaults match the docker-compose mounts):
#   PIPELINE_INPUT_DIR   source data, read only        (default /data/raw)
#   PIPELINE_OUTPUT_DIR  .pmtiles, .cog.tif, manifest.json and style.json
#                                                      (default /data/tiles)
#   PIPELINE_LAYERS_DIR  layer configs                 (default <pipeline>/layers)
#   PIPELINE_MAP_CONFIG  local map config; none if unset or the file is
#                        missing                       (default unset)
#   PIPELINE_WORK_DIR    cache kept between runs: raster sources prepared
#                        once (raster/; lib/raster.sh). Empty for no cache.
#                                                      (default /data/work)
#   TMPDIR               parent of the scratch dir     (default /tmp)
#
# A build or style-only run attempts every layer; the exit status is 1 if
# any layer failed (or anything else went wrong), 2 for a usage error
# (including a layer with no config to build, a problem in the map config,
# nothing built to restyle or remove), 0 otherwise.
set -euo pipefail

PIPELINE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PIPELINE_ROOT

# shellcheck source=lib/log.sh
source "${PIPELINE_ROOT}/lib/log.sh"
# shellcheck source=lib/config.sh
source "${PIPELINE_ROOT}/lib/config.sh"
# shellcheck source=lib/normalise.sh
source "${PIPELINE_ROOT}/lib/normalise.sh"
# shellcheck source=lib/tiles.sh
source "${PIPELINE_ROOT}/lib/tiles.sh"
# shellcheck source=lib/guard.sh
source "${PIPELINE_ROOT}/lib/guard.sh"
# shellcheck source=lib/generalise.sh
source "${PIPELINE_ROOT}/lib/generalise.sh"
# shellcheck source=lib/manifest.sh
source "${PIPELINE_ROOT}/lib/manifest.sh"
# shellcheck source=lib/display.sh
source "${PIPELINE_ROOT}/lib/display.sh"
# shellcheck source=lib/raster.sh
source "${PIPELINE_ROOT}/lib/raster.sh"
# shellcheck source=lib/status.sh
source "${PIPELINE_ROOT}/lib/status.sh"
# shellcheck source=lib/mapconfig.sh
source "${PIPELINE_ROOT}/lib/mapconfig.sh"
# shellcheck source=lib/derive.sh
source "${PIPELINE_ROOT}/lib/derive.sh"

PIPELINE_INPUT_DIR=${PIPELINE_INPUT_DIR:-/data/raw}
PIPELINE_OUTPUT_DIR=${PIPELINE_OUTPUT_DIR:-/data/tiles}
PIPELINE_LAYERS_DIR=${PIPELINE_LAYERS_DIR:-${PIPELINE_ROOT}/layers}
PIPELINE_WORK_DIR=${PIPELINE_WORK_DIR-/data/work}

usage() {
  # The header comment block, skipping the shebang and shellcheck lines.
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# build_layer NAME SCRATCH: run in a subshell, so `die` (and the config's
# variables) stay inside one layer. The settings and display config are
# the layer set's (lib/mapconfig.sh): the committed files, or copies with
# the map config's overrides.
build_layer() {
  local name=$1 scratch=$2
  PIPELINE_LOG_PREFIX=$name
  local env style
  env=$(layer_get "$name" env)
  style=$(layer_get "$name" style)

  load_layer_config "$env"
  source_mtime "$LAYER_INPUT" >/dev/null || die "input not found: $LAYER_INPUT"

  local layer_scratch="${scratch}/${name}"
  mkdir -p "$layer_scratch"
  local started=$SECONDS
  local display="${layer_scratch}/display.json" report="${layer_scratch}/report.json"
  local header="${layer_scratch}/header.json" header_json=""
  # Set by build_vector_layer for a layer with a rules table (lib/derive.sh).
  local rules_sha=""

  if [[ $LAYER_TYPE == raster ]]; then
    build_raster_layer
    header_json=$(jq -c '.' "$header")
  else
    build_vector_layer
  fi

  # The rules table's hash joins the provenance, so --status sees a change.
  local provenance
  provenance=$(layer_provenance "$name" "$LAYER_INPUT" \
    | jq -c --arg r "$rules_sha" '.rules_sha256 = (if $r == "" then null else $r end)')
  manifest_update "$PIPELINE_OUTPUT_DIR" "$name" "$LAYER_TYPE" "$display" \
    "$(jq -c '.' "$report")" "$((SECONDS - started))" "$provenance" "$header_json"
  remove_other_archives "$name" "$(layer_archive_file "$name" "$LAYER_TYPE")"
}

# remove_other_archives NAME KEEP: delete NAME's archives other than KEEP
# (a file name in the output dir), such as a raster layer's .pmtiles from
# before COGs (ADR 0010), once the manifest no longer names them.
remove_other_archives() {
  local name=$1 keep=$2 path
  while IFS= read -r path; do
    [[ -n $path && ${path##*/} != "$keep" ]] || continue
    rm -f -- "$path"
    log_info "removed the old archive ${path##*/}"
  done < <(layer_archives "$PIPELINE_OUTPUT_DIR" "$name" || true)
}

# build_vector_layer: the vector steps of build_layer, whose locals (name,
# style, layer_scratch, display, report) it reads and writes.
build_vector_layer() {
  local normalised="${layer_scratch}/${name}.geojsonl"

  # Calculated fields and rules (lib/derive.sh): checked before the source
  # data is read, added to the normalised data, then tiled like the rest.
  local plan="" derived=()
  if layer_derives; then
    plan="${layer_scratch}/derive.json"
    derive_plan "$name" "$name" "$plan"
    mapfile -t derived < <(jq -r '.attributes[]' "$plan")
    rules_sha=$(jq -r '.rules.sha256 // empty' "$plan")
  fi

  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" \
    "$LAYER_ENCODING" "$normalised" "${LAYER_FIELDS[@]}"
  if [[ -n $plan ]]; then derive_apply "$normalised" "$plan"; fi

  local count
  count=$(wc -l <"$normalised")
  count=${count//[[:space:]]/}
  ((count > 0)) || die "no features after normalising $LAYER_INPUT"
  log_info "$count features"

  # The display config is checked before tiling, so a bad one costs nothing
  # and leaves the previous archive and manifest entry in place.
  resolve_display "$name" "$style" "$normalised" "$display"

  local sizes="${layer_scratch}/sizes.tsv" stats="${layer_scratch}/zoom_stats.json"
  feature_sizes "$normalised" "$LAYER_FEATURE_ID" "$sizes"

  # With low-zoom generalisation, tippecanoe reads the generalised zooms
  # and the full input from one file (lib/generalise.sh); the drop guard
  # still measures the full input.
  local tile_input=$normalised
  if [[ -n $LAYER_GENERALISE_MAX_ZOOM ]]; then
    tile_input="${layer_scratch}/${name}.generalised.geojsonl"
    generalised_input "$normalised" "$tile_input" "$LAYER_MIN_ZOOM" \
      "$LAYER_GENERALISE_MAX_ZOOM" "$LAYER_FEATURE_ID" "$LAYER_GENERALISE_MIN_PART_PX" \
      "$LAYER_GENERALISE_SIMPLIFY_PX" "$layer_scratch" "${LAYER_FIELDS[@]}" "${derived[@]}"
  fi

  build_tiles "$name" "$tile_input" "$PIPELINE_OUTPUT_DIR" \
    "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$LAYER_FEATURE_ID" "$layer_scratch" \
    check_layer_tiles "${LAYER_TIPPECANOE_FLAGS[@]}"

  vector_report "$count" "$stats" "$LAYER_PROFILE" "$LAYER_MIN_VISIBLE_PX" >"$report"
  if [[ -n $plan ]]; then
    local derive_json
    derive_json=$(derive_report "$normalised" "$plan")
    log_info "$(derive_summary "$derive_json")"
    jq -c --argjson d "$derive_json" '. + $d' "$report" >"${report}.tmp"
    mv -- "${report}.tmp" "$report"
  fi
}

# check_layer_tiles ARCHIVE: the drop guard, run by build_tiles from inside
# build_vector_layer, whose locals (name, sizes, count, stats) it reads.
check_layer_tiles() {
  drop_guard "$1" "$name" "$sizes" "$count" "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" \
    "$LAYER_MIN_VISIBLE_PX" "$stats"
}

# build_raster_layer: the raster steps of build_layer (lib/raster.sh), whose
# locals (name, style, layer_scratch, display, report) it reads and writes.
build_raster_layer() {
  # Checked first, as for a vector layer, so a bad config costs nothing. The
  # colour is not in the tiles (lib/raster.sh), only in the display block.
  resolve_display "$name" "$style" - "$display" raster

  build_raster_tiles "$name" "$LAYER_INPUT" "$LAYER_SOURCE_SRS" "$LAYER_NODATA" \
    "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$PIPELINE_OUTPUT_DIR" "$layer_scratch" "$report" \
    "$header" "${PIPELINE_WORK_DIR:+${PIPELINE_WORK_DIR}/raster}"
}

# restyle_layer NAME SCRATCH: the --style-only steps for one built layer, in
# a subshell like build_layer: resolve its display config (with the map
# config's overrides) for the type the archive was built as, and put it in
# the manifest entry. The archive is not touched; a bad config fails the
# layer and keeps its entry as it was.
restyle_layer() {
  local name=$1 scratch=$2
  PIPELINE_LOG_PREFIX=$name
  local manifest="${PIPELINE_OUTPUT_DIR}/manifest.json"
  local style
  style=$(layer_get "$name" style)
  style=${style:-${PIPELINE_LAYERS_DIR}/${name}.style.json}
  local layer_scratch="${scratch}/${name}" type data=-
  mkdir -p "$layer_scratch"
  local display="${layer_scratch}/display.json"

  type=$(jq -er --arg n "$name" 'first(.layers[] | select(.name == $n)) | .type // "vector"' \
    "$manifest") || die "no entry for $name in $manifest"

  # `breaks` are computed from the data, which the tiles do not give back.
  if [[ $type == vector ]] \
    && jq -e 'any(.symbology.color? | objects; .breaks != null)' "$style" >/dev/null 2>&1; then
    data="${layer_scratch}/${name}.geojsonl"
    restyle_data "$name" "$manifest" "$data"
  fi

  resolve_display "$name" "$style" "$data" "$display" "$type"
  manifest_set_display "$PIPELINE_OUTPUT_DIR" "$name" "$display" \
    "$(layer_display_provenance "$name")"
}

# restyle_data NAME MANIFEST OUT: normalise NAME's source data to OUT, as
# its build did, for a display config with `breaks`. Fails if the .env, the
# map config's input or env, or the source data changed since the build, as
# the breaks would then not match the tiles: rebuild the layer instead.
restyle_data() {
  local name=$1 manifest=$2 out=$3
  local env env_source
  env=$(layer_get "$name" env)
  env_source=$(layer_get "$name" envSource)
  [[ -n $env && -f $env ]] \
    || die "the display config has breaks, which need ${name}.env and the source data"
  load_layer_config "$env"

  local built_at changed src recorded current
  built_at=$(jq -r --arg n "$name" \
    'first(.layers[] | select(.name == $n)) | (.built_at | fromdateiso8601?) // 0' "$manifest")
  recorded=$(jq -r --arg n "$name" \
    'first(.layers[] | select(.name == $n)) | .provenance.env_sha256 // ""' "$manifest")
  current=$(layer_get "$name" envSha256)
  src=$(source_mtime "$LAYER_INPUT") || die "input not found: $LAYER_INPUT"
  changed=$(_newest_mtime "$env_source")
  if ((${src:-0} > ${changed:-0})); then changed=$src; fi
  ((${changed:-0} <= built_at)) && [[ -z $recorded || $recorded == "$current" ]] \
    || die "the display config has breaks, computed from the data, and ${name}.env, the map config's input or env, or the source data changed since the build: rebuild the layer"

  # Breaks may be on a calculated field (lib/derive.sh), so they are added
  # as the build added them, from the same rules table.
  local plan=""
  if layer_derives; then
    plan="${out%/*}/derive.json"
    derive_plan "$name" "$(basename "$out" .geojsonl)" "$plan"
    recorded=$(jq -r --arg n "$name" \
      'first(.layers[] | select(.name == $n)) | .provenance.rules_sha256 // ""' "$manifest")
    [[ $(jq -r '.rules.sha256 // ""' "$plan") == "$recorded" ]] \
      || die "the display config has breaks, computed from the data, and the rules table changed since the build: rebuild the layer"
  fi

  log_info "reading the source data for breaks (no tiling)"
  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" \
    "$LAYER_ENCODING" "$out" "${LAYER_FIELDS[@]}"
  if [[ -n $plan ]]; then derive_apply "$out" "$plan"; fi
}

# finish_manifest: apply the map config's layer selection and map view to
# the manifest (lib/manifest.sh) and rewrite style.json from it. Returns 1
# if either fails.
finish_manifest() {
  set +e
  (
    manifest_apply_config "$PIPELINE_OUTPUT_DIR" "$LAYERS_JSON"
    write_style "$PIPELINE_OUTPUT_DIR"
  )
  local status=$?
  set -e
  return "$status"
}

# style_only_main SCRATCH LAYER...: the --style-only mode. With no names,
# every enabled layer in the manifest whose archive and display config
# exist. Every named layer is checked before any is updated; then each is
# attempted, as in a build, and style.json is rewritten from the manifest.
style_only_main() {
  local scratch=$1
  shift
  local manifest="${PIPELINE_OUTPUT_DIR}/manifest.json" layers=("$@") name style
  if ((${#layers[@]} == 0)); then
    if [[ ! -s $manifest ]]; then
      log_error "no layers built in $PIPELINE_OUTPUT_DIR: build them first"
      return 2
    fi
    local built
    built=$(jq -r '.layers[]?.name' "$manifest") || die "cannot read $manifest"
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      style=$(layer_get "$name" style)
      if ! layer_archive "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null; then
        log_warn "skipping $name: archive missing (rebuild it)"
      elif [[ -z $style || ! -f $style ]]; then
        log_warn "skipping $name: no ${name}.style.json in $PIPELINE_LAYERS_DIR"
      elif ! layer_enabled "$name"; then
        log_info "skipping $name: not enabled in the map config"
      else
        layers+=("$name")
      fi
    done <<<"$built"
    if ((${#layers[@]} == 0)); then
      log_error "no built layers with a display config to update"
      return 2
    fi
  fi

  for name in "${layers[@]}"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_archive "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null \
      || ! jq -e --arg n "$name" 'any(.layers[]?; .name == $n)' "$manifest" >/dev/null 2>&1; then
      log_error "layer '$name' is not built yet: build it first (run.sh $name)"
      return 2
    fi
    if layer_known "$name" && ! layer_enabled "$name"; then
      log_error "layer '$name' is not enabled in the map config"
      return 2
    fi
  done
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  local failed=() status
  for name in "${layers[@]}"; do
    set +e
    (restyle_layer "$name" "$scratch")
    status=$?
    set -e
    if ((status == 0)); then
      log_info "layer $name: display updated"
    else
      log_error "layer $name: display not updated (exit $status)"
      failed+=("$name")
    fi
  done

  local style_status=0
  finish_manifest || style_status=$?

  if ((${#failed[@]} > 0)); then
    log_error "${#failed[@]} of ${#layers[@]} layer(s) failed: ${failed[*]}"
    return 1
  fi
  ((style_status == 0)) || return 1
  log_info "display updated for ${#layers[@]} layer(s), no tiles rebuilt"
}

# require_tools TOOL...: fail unless every TOOL is on the PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "required tool not found: $tool"
  done
}

# status_main JSON LAYER...: the --status mode. JSON is 1 for JSON output.
status_main() {
  local json=$1 name
  shift
  for name in "$@"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_known "$name" && ! layer_archives "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null \
      && ! jq -e --arg n "$name" 'any(.layers[]?; .name == $n)' \
        "${PIPELINE_OUTPUT_DIR}/manifest.json" >/dev/null 2>&1; then
      log_error "no config or build for layer '$name'"
      return 2
    fi
  done

  local status
  status=$(layer_status_json "$PIPELINE_OUTPUT_DIR" "$@")
  if ((json)); then
    printf '%s\n' "$status"
  else
    print_layer_status <<<"$status"
  fi
}

# remove_main LAYER...: the --remove mode. Every layer is checked before any
# is removed. Each manifest entry goes before its archive, so the map never
# lists a layer whose archive is gone.
remove_main() {
  if (($# == 0)); then
    log_error "--remove needs at least one layer name"
    return 2
  fi
  local manifest="${PIPELINE_OUTPUT_DIR}/manifest.json" name
  for name in "$@"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_archives "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null \
      && ! jq -e --arg n "$name" 'any(.layers[]; .name == $n)' "$manifest" >/dev/null 2>&1; then
      log_error "nothing built for layer '$name' in $PIPELINE_OUTPUT_DIR"
      return 2
    fi
  done
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  for name in "$@"; do
    manifest_remove "$PIPELINE_OUTPUT_DIR" "$name"
    remove_other_archives "$name" ""
    log_info "removed layer $name"
    if [[ $(layer_get "$name" origin) == committed ]]; then
      log_warn "${name}.env is still in ${PIPELINE_LAYERS_DIR}: delete its configs, or the next full build makes the layer again"
    elif layer_enabled "$name"; then
      log_warn "layer $name is still configured ($(layer_where "$name")): remove it there or disable it in the map config, or the next full build makes it again"
    fi
  done
  (write_style "$PIPELINE_OUTPUT_DIR")
}

# missing_source NAME: print why NAME's source data is not found, or
# nothing (and return 1) if it is there or the config does not load (the
# build then reports that).
missing_source() {
  local cfg input
  cfg=$(_config_input "$(layer_get "$1" env)")
  [[ ${cfg%%$'\t'*} == ok ]] || return 1
  input=${cfg##*$'\t'}
  ! source_mtime "$input" >/dev/null || return 1
  printf 'source data not found: %s\n' "${input#"${PIPELINE_INPUT_DIR}"/}"
}

# build_main SCRATCH LAYER...: the build mode.
build_main() {
  local scratch=$1
  shift
  local layers=("$@") name all=0
  require_tools gdal gdalwarp gdaladdo gdalinfo ogr2ogr ogrinfo tippecanoe \
    tippecanoe-decode pmtiles

  if ((${#layers[@]} == 0)); then
    all=1
    mapfile -t layers < <(layer_names enabled)
    if ((${#layers[@]} == 0)); then
      if [[ -n $(layer_names) ]]; then
        die "no layers are enabled in the map config"
      fi
      die "no layer configs in $PIPELINE_LAYERS_DIR"
    fi
  fi

  # Check every requested layer before building any of them.
  for name in "${layers[@]}"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_known "$name"; then
      log_error "no config for layer '$name' in $PIPELINE_LAYERS_DIR or the map config"
      return 2
    fi
    if ! layer_enabled "$name"; then
      log_error "layer '$name' is not enabled in the map config: enable it there to build it"
      return 2
    fi
  done

  mkdir -p "$PIPELINE_OUTPUT_DIR" || die "cannot create $PIPELINE_OUTPUT_DIR"
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  # A full build skips layers whose source data is not there (for example
  # a layer for data you do not have); a named one fails instead.
  local skipped=() why
  if ((all)); then
    local to_build=()
    for name in "${layers[@]}"; do
      if why=$(missing_source "$name"); then
        log_warn "skipping $name: $why"
        skipped+=("$name")
      else
        to_build+=("$name")
      fi
    done
    layers=("${to_build[@]}")
  fi

  log_info "input $PIPELINE_INPUT_DIR, output $PIPELINE_OUTPUT_DIR, layers: ${layers[*]:-none}"

  local failed=() status
  for name in "${layers[@]}"; do
    log_info "layer $name: start"
    # set +e around the subshell rather than `if ! (...)`: in a tested
    # context bash ignores `set -e` inside the subshell too.
    set +e
    (build_layer "$name" "$scratch")
    status=$?
    set -e
    if ((status == 0)); then
      log_info "layer $name: done"
    else
      log_error "layer $name: failed (exit $status)"
      failed+=("$name")
    fi
  done

  # The combined style follows the manifest, including entries kept from
  # earlier runs, so it is rewritten even when a layer failed.
  local style_status=0
  finish_manifest || style_status=$?

  if ((${#skipped[@]} > 0)); then
    log_warn "${#skipped[@]} layer(s) skipped, source data not found: ${skipped[*]}"
  fi
  if ((${#failed[@]} > 0)); then
    log_error "${#failed[@]} of ${#layers[@]} layer(s) failed: ${failed[*]}"
    return 1
  fi
  if ((${#layers[@]} == 0)); then
    log_error "nothing to build: no enabled layer has its source data (input dir $PIPELINE_INPUT_DIR)"
    return 1
  fi
  ((style_status == 0)) || return 1
  log_info "all ${#layers[@]} layer(s) built${skipped[*]:+, ${#skipped[@]} skipped}"
}

main() {
  local arg mode=build json=0 layers=()
  for arg in "$@"; do
    case $arg in
      -h | --help)
        usage
        return 0
        ;;
      --status | --list | --remove | --style-only)
        local wanted=status
        case $arg in
          --remove) wanted=remove ;;
          --style-only) wanted=style ;;
        esac
        if [[ $mode != build && $mode != "$wanted" ]]; then
          log_error "--status, --remove and --style-only cannot be used together"
          return 2
        fi
        mode=$wanted
        ;;
      --json) json=1 ;;
      -*)
        log_error "unknown option: $arg"
        usage >&2
        return 2
        ;;
      *) layers+=("$arg") ;;
    esac
  done
  if ((json)) && [[ $mode != status ]]; then
    log_error "--json works only with --status"
    return 2
  fi

  require_tools jq node
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/pipeline.XXXXXX")
  # shellcheck disable=SC2064 # expand now: scratch is local to main.
  trap "rm -rf '${scratch}'" EXIT

  # The layer set: the committed configs plus the map config, if any. A
  # problem in the map config stops every mode before anything changes.
  local status=0
  resolve_layers "${scratch}/resolved" || status=$?
  ((status == 0)) || return "$status"

  case $mode in
    status) status_main "$json" "${layers[@]}" ;;
    remove) remove_main "${layers[@]}" ;;
    style) style_only_main "$scratch" "${layers[@]}" ;;
    *) build_main "$scratch" "${layers[@]}" ;;
  esac
}

main "$@"
