#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Pipeline entry point: build tiles (vector tiles in a .pmtiles archive, or
# one COG for a raster layer, ADR 0010) for every layer, or only the layers
# named on the command line. Each layer is one file, <layer>.yaml in
# pipeline/layers/, or pipeline/layers.local/ for your own (git-ignored;
# schema/layer.schema.json, design note 04): its source,
# fields, processing preset and display. A map config (PIPELINE_MAP_CONFIG;
# map.config.yaml at the repo root under compose, map.pages.yaml for the
# GitHub Pages copy; schema/map.schema.json) can pick the layers, override
# their source and processing, require sources and set the view, title and
# number locale of the map;
# without one every layer is built as it is.
#
# Usage: run.sh [-h|--help] [layer ...]
#        run.sh --status [--json] [layer ...]
#        run.sh --style-only [layer ...]
#        run.sh --remove layer ...
#
#   (no option)  build the named layers, or every layer the map config
#                picks. With no names, a layer whose source data is not
#                found is skipped with a warning (the run fails only if
#                nothing could be built), unless the map config's `require`
#                names it: then nothing is built. A named layer with no
#                source data fails.
#   --style-only update the named layers' display from their layer file, or
#                every built and enabled layer's, without re-tiling: rewrite
#                their part of style.json (build.json keeps the build
#                report and records the display hash). For a change to a
#                layer file's `display`, `title`, `visible` or `order` (of a
#                vector or raster layer), or to the map config's layer
#                selection or view.
#   --status     list every configured or built layer (or the named ones)
#                with its state: current, stale (the layer file's source,
#                fields or processing, the map config's overrides of them,
#                or the source data changed since the build), restyle (only
#                the display changed: --style-only is enough), not built,
#                source missing (a full build skips it), invalid (the layer
#                file has problems), disabled (left out by the map config)
#                or orphan (built, layer file gone), plus build time,
#                archive size, zooms, feature count (size in pixels for a
#                raster layer) and largest tile. Read only. --list is the
#                same.
#   --json       with --status: print JSON instead of a table.
#   --remove     delete the named layers' archives and build.json entries
#                and rewrite style.json. The layer files are not touched:
#                delete them first (git rm), or the next full build makes
#                the layer again.
#
# Environment (defaults match the docker-compose mounts):
#   PIPELINE_INPUT_DIR   source data, read only        (default /data/raw)
#   PIPELINE_OUTPUT_DIR  .pmtiles, .cog.tif, style.json (read by the map,
#                        lib/style.sh) and build.json (the build report,
#                        lib/build.sh)
#                                                      (default /data/tiles)
#   PIPELINE_LAYERS_DIR  layer files                   (default <pipeline>/layers)
#   PIPELINE_LOCAL_LAYERS_DIR
#                        your own layer files (layers.local/, git-ignored),
#                        built like the others; a name that repeats a
#                        committed layer is an error. Empty for none.
#                                                      (default <pipeline>/layers.local)
#   PIPELINE_MAP_CONFIG  map config; none if unset or the file is missing
#                                                      (default unset)
#   PIPELINE_WORK_DIR    cache kept between runs: raster sources prepared
#                        once (raster/; lib/raster.sh). Empty for no cache.
#                                                      (default /data/work)
#   TMPDIR               parent of the scratch dir     (default /tmp)
#
# A build or style-only run attempts every layer; the exit status is 1 if
# any layer failed (or anything else went wrong), 2 for a usage error
# (including a layer with no layer file, a problem in the map config,
# nothing built to restyle or remove), 0 otherwise.
set -euo pipefail

PIPELINE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PIPELINE_ROOT

# shellcheck source=lib/log.sh
source "${PIPELINE_ROOT}/lib/log.sh"
# shellcheck source=lib/layerfile.sh
source "${PIPELINE_ROOT}/lib/layerfile.sh"
# shellcheck source=lib/normalise.sh
source "${PIPELINE_ROOT}/lib/normalise.sh"
# shellcheck source=lib/calculated.sh
source "${PIPELINE_ROOT}/lib/calculated.sh"
# shellcheck source=lib/tiles.sh
source "${PIPELINE_ROOT}/lib/tiles.sh"
# shellcheck source=lib/guard.sh
source "${PIPELINE_ROOT}/lib/guard.sh"
# shellcheck source=lib/generalise.sh
source "${PIPELINE_ROOT}/lib/generalise.sh"
# shellcheck source=lib/build.sh
source "${PIPELINE_ROOT}/lib/build.sh"
# shellcheck source=lib/style.sh
source "${PIPELINE_ROOT}/lib/style.sh"
# shellcheck source=lib/raster.sh
source "${PIPELINE_ROOT}/lib/raster.sh"
# shellcheck source=lib/status.sh
source "${PIPELINE_ROOT}/lib/status.sh"

PIPELINE_INPUT_DIR=${PIPELINE_INPUT_DIR:-/data/raw}
PIPELINE_OUTPUT_DIR=${PIPELINE_OUTPUT_DIR:-/data/tiles}
PIPELINE_LAYERS_DIR=${PIPELINE_LAYERS_DIR:-${PIPELINE_ROOT}/layers}
PIPELINE_LOCAL_LAYERS_DIR=${PIPELINE_LOCAL_LAYERS_DIR-${PIPELINE_ROOT}/layers.local}
PIPELINE_WORK_DIR=${PIPELINE_WORK_DIR-/data/work}

usage() {
  # The header comment block, skipping the shebang and shellcheck lines.
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# build_layer NAME SCRATCH: run in a subshell, so `die` (and the layer's
# variables) stay inside one layer. The layer is its effective layer file
# (lib/layerfile.sh): the file with the map config's overrides.
build_layer() {
  local name=$1 scratch=$2
  PIPELINE_LOG_PREFIX=$name
  load_layer "$name"
  source_mtime "$LAYER_INPUT" >/dev/null || die "input not found: $LAYER_INPUT"

  local layer_scratch="${scratch}/${name}"
  mkdir -p "$layer_scratch"
  local started=$SECONDS
  local report="${layer_scratch}/report.json"
  local header="${layer_scratch}/header.json" header_json=""

  if [[ $LAYER_TYPE == raster ]]; then
    build_raster_tiles "$name" "$LAYER_INPUT" "$LAYER_SOURCE_SRS" "$LAYER_NODATA" \
      "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$PIPELINE_OUTPUT_DIR" "$layer_scratch" "$report" \
      "$header" "$LAYER_GREY_LEVELS" "${PIPELINE_WORK_DIR:+${PIPELINE_WORK_DIR}/raster}"
    header_json=$(jq -c '.' "$header")
  else
    build_vector_layer
  fi

  build_update "$PIPELINE_OUTPUT_DIR" "$name" "$LAYER_TYPE" \
    "$(jq -c '.' "$report")" "$((SECONDS - started))" \
    "$(layer_provenance "$name" "$LAYER_INPUT")" "$header_json"
  remove_other_archives "$name" "$(layer_archive_file "$name" "$LAYER_TYPE")"
}

# remove_other_archives NAME KEEP: delete NAME's archives other than KEEP
# (a file name in the output dir), such as a raster layer's .pmtiles from
# before COGs (ADR 0010), once build.json no longer names them.
remove_other_archives() {
  local name=$1 keep=$2 path
  while IFS= read -r path; do
    [[ -n $path && ${path##*/} != "$keep" ]] || continue
    rm -f -- "$path"
    log_info "removed the old archive ${path##*/}"
  done < <(layer_archives "$PIPELINE_OUTPUT_DIR" "$name" || true)
}

# build_vector_layer: the vector steps of build_layer, whose locals (name,
# layer_scratch, report) it reads and writes.
build_vector_layer() {
  local normalised="${layer_scratch}/${name}.geojsonl"
  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" \
    "$LAYER_ENCODING" "$normalised" "${LAYER_FIELDS[@]}"

  local count
  count=$(wc -l <"$normalised")
  count=${count//[[:space:]]/}
  ((count > 0)) || die "no features after normalising $LAYER_INPUT"
  log_info "$count features"

  # Calculated fields (lib/calculated.sh), added to the normalised data and
  # then tiled like the rest.
  local calculated=""
  if ((${#LAYER_CALCULATED_NAMES[@]} > 0)); then
    calculated="${layer_scratch}/calculated.json"
    add_calculated_fields "$normalised" "${layer_scratch}/${name}.calculated.geojsonl" "$calculated"
    mv -f -- "${layer_scratch}/${name}.calculated.geojsonl" "$normalised"
    log_info "$(calculated_summary "$calculated")"
  fi

  local sizes="${layer_scratch}/sizes.tsv" stats="${layer_scratch}/zoom_stats.json"
  feature_sizes "$normalised" "$LAYER_FEATURE_ID" "$sizes"

  # The coverage preset generalises every zoom below the max: tippecanoe
  # reads the generalised zooms and the full input from one file
  # (lib/generalise.sh); the drop guard still measures the full input.
  local tile_input=$normalised
  if [[ -n $LAYER_GENERALISE_MAX_ZOOM ]]; then
    local field attributes=()
    for field in "${LAYER_FIELDS[@]}"; do attributes+=("${field#*:}"); done
    tile_input="${layer_scratch}/${name}.generalised.geojsonl"
    generalised_input "$normalised" "$tile_input" "$LAYER_MIN_ZOOM" \
      "$LAYER_GENERALISE_MAX_ZOOM" "$LAYER_FEATURE_ID" "$LAYER_GENERALISE_MIN_PART_PX" \
      "$LAYER_GENERALISE_SIMPLIFY_PX" "$layer_scratch" "${attributes[@]}" \
      "${LAYER_CALCULATED_NAMES[@]}"
  fi

  build_tiles "$name" "$tile_input" "$PIPELINE_OUTPUT_DIR" \
    "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$LAYER_FEATURE_ID" "$layer_scratch" \
    check_layer_tiles "${LAYER_TIPPECANOE_FLAGS[@]}"

  vector_report "$count" "$stats" "$LAYER_PROFILE" "$LAYER_MIN_VISIBLE_PX" >"$report"
  if [[ -n $calculated ]]; then
    jq -c --slurpfile c "$calculated" '. + {calculated_fields: $c[0]}' "$report" >"${report}.tmp"
    mv -- "${report}.tmp" "$report"
  fi
}

# check_layer_tiles ARCHIVE: the drop guard, run by build_tiles from inside
# build_vector_layer, whose locals (name, sizes, count, stats) it reads.
check_layer_tiles() {
  drop_guard "$1" "$name" "$sizes" "$count" "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" \
    "$LAYER_MIN_VISIBLE_PX" "$stats"
}

# restyle_layer NAME: the --style-only checks for one built layer, in a
# subshell like build_layer: its layer file has no problems and the build
# is of the same type. style.json then takes its display from the layer
# file (write_style). The archive is not touched; a layer that fails keeps
# its part of style.json as it was.
restyle_layer() {
  local name=$1
  PIPELINE_LOG_PREFIX=$name
  layer_check "$name"
  local report="${PIPELINE_OUTPUT_DIR}/build.json" built type
  built=$(jq -er --arg n "$name" 'first(.layers[] | select(.name == $n)) | .type // "vector"' \
    "$report") || die "no entry for $name in $report"
  type=$(layer_get "$name" type)
  [[ $built == "$type" ]] \
    || die "built as a $built layer, but ${name}.yaml is a $type layer now: rebuild it"
}

# finish_style [LAYER...]: rewrite style.json (lib/style.sh) from build.json
# and the map config, the named layers' display from their layer files.
# Returns 1 if it fails.
finish_style() {
  set +e
  (write_style "$PIPELINE_OUTPUT_DIR" "$@")
  local status=$?
  set -e
  return "$status"
}

# style_only_main LAYER...: the --style-only mode. With no names, every
# enabled layer in build.json whose archive and layer file exist. Every
# named layer is checked before any is updated; then each is attempted, as
# in a build, and style.json is rewritten with the ones that passed.
style_only_main() {
  local report="${PIPELINE_OUTPUT_DIR}/build.json" layers=("$@") name
  if ((${#layers[@]} == 0)); then
    if [[ ! -s $report ]]; then
      log_error "no layers built in $PIPELINE_OUTPUT_DIR: build them first"
      return 2
    fi
    local built
    built=$(jq -r '.layers[]?.name' "$report") || die "cannot read $report"
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      if ! layer_archive "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null; then
        log_warn "skipping $name: archive missing (rebuild it)"
      elif ! layer_known "$name"; then
        log_warn "skipping $name: no ${name}.yaml in $(layer_dirs)"
      elif ! layer_enabled "$name"; then
        log_info "skipping $name: not enabled in the map config"
      else
        layers+=("$name")
      fi
    done <<<"$built"
    if ((${#layers[@]} == 0)); then
      log_error "no built layers with a layer file to update"
      return 2
    fi
  fi

  for name in "${layers[@]}"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_archive "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null \
      || ! build_has "$PIPELINE_OUTPUT_DIR" "$name"; then
      log_error "layer '$name' is not built yet: build it first (run.sh $name)"
      return 2
    fi
    if ! layer_known "$name"; then
      log_error "no layer file for '$name' in $(layer_dirs)"
      return 2
    fi
    if ! layer_enabled "$name"; then
      log_error "layer '$name' is not enabled in the map config"
      return 2
    fi
  done
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  local failed=() restyled=() status
  for name in "${layers[@]}"; do
    set +e
    (restyle_layer "$name")
    status=$?
    set -e
    if ((status == 0)); then
      restyled+=("$name")
    else
      log_error "layer $name: display not updated (exit $status)"
      failed+=("$name")
    fi
  done

  local style_status=0
  finish_style "${restyled[@]}" || style_status=$?
  if ((style_status == 0)); then
    for name in "${restyled[@]}"; do log_info "layer $name: display updated"; done
  fi

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
      && ! build_has "$PIPELINE_OUTPUT_DIR" "$name"; then
      log_error "no layer file or build for layer '$name'"
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
# is removed: its build.json entry, then its archives; style.json is then
# rewritten without it.
remove_main() {
  if (($# == 0)); then
    log_error "--remove needs at least one layer name"
    return 2
  fi
  local name file
  for name in "$@"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_archives "$PIPELINE_OUTPUT_DIR" "$name" >/dev/null \
      && ! build_has "$PIPELINE_OUTPUT_DIR" "$name"; then
      log_error "nothing built for layer '$name' in $PIPELINE_OUTPUT_DIR"
      return 2
    fi
  done
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  for name in "$@"; do
    build_remove "$PIPELINE_OUTPUT_DIR" "$name"
    remove_other_archives "$name" ""
    log_info "removed layer $name"
    if layer_enabled "$name"; then
      file=$(layer_get "$name" file)
      log_warn "${name}.yaml is still in ${file%/*}: delete it (or leave it out of the map config's layers), or the next full build makes the layer again"
    fi
  done
  (write_style "$PIPELINE_OUTPUT_DIR")
}

# missing_source NAME: print why NAME's source data is not found, or
# nothing (and return 1) if it is there or the layer file has problems
# (the build then reports those).
missing_source() {
  local input
  input=$(layer_get "$1" input)
  [[ -n $input ]] || return 1
  ! source_mtime "$input" >/dev/null || return 1
  printf 'source data not found: %s\n' "${input#"${PIPELINE_INPUT_DIR}"/}"
}

# check_required: the map config's `require`, before a build: every layer it
# names must have its source data, or nothing is built (for the GitHub
# Pages copy, which must use the public protected areas source, ADR 0014).
# Returns 1, after naming each missing one.
check_required() {
  local name why bad=0
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    if why=$(missing_source "$name"); then
      log_error "$name: $why, and the map config requires it (require): nothing was built"
      bad=1
    fi
  done < <(jq -r '.require[]' "$LAYERS_JSON")
  ((bad == 0))
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
      die "no layer files in $(layer_dirs)"
    fi
  fi

  # Check every requested layer before building any of them.
  for name in "${layers[@]}"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if ! layer_known "$name"; then
      log_error "no layer file for layer '$name' in $(layer_dirs)"
      return 2
    fi
    if ! layer_enabled "$name"; then
      log_error "layer '$name' is not enabled in the map config: add it to its layers to build it"
      return 2
    fi
  done

  check_required || return 1

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

  local failed=() built=() status
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
      built+=("$name")
    else
      log_error "layer $name: failed (exit $status)"
      failed+=("$name")
    fi
  done

  # The style follows build.json, including layers kept from earlier runs,
  # so it is rewritten even when a layer failed.
  local style_status=0
  finish_style "${built[@]}" || style_status=$?

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

  require_tools jq yq jv
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/pipeline.XXXXXX")
  # shellcheck disable=SC2064 # expand now: scratch is local to main.
  trap "rm -rf '${scratch}'" EXIT

  # The layer files and the map config, checked. A problem in the map
  # config stops every mode before anything changes.
  local status=0
  resolve_layers "${scratch}/resolved" || status=$?
  ((status == 0)) || return "$status"

  case $mode in
    status) status_main "$json" "${layers[@]}" ;;
    remove) remove_main "${layers[@]}" ;;
    style) style_only_main "${layers[@]}" ;;
    *) build_main "$scratch" "${layers[@]}" ;;
  esac
}

main "$@"
