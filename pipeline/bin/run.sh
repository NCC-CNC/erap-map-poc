#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Pipeline entry point: build tiles (vector, or PNG for raster layers) for
# every layer config in pipeline/layers/, or only the layers named on the
# command line. Each layer is <layer>.env (processing; LAYER_TYPE picks
# vector or raster) plus <layer>.style.json (display, ADR 0007; rasters,
# ADR 0008).
#
# Usage: run.sh [-h|--help] [layer ...]
#        run.sh --status [--json] [layer ...]
#        run.sh --remove layer ...
#
#   (no option)  build the named layers, or every layer with a config.
#   --status     list every configured or built layer (or the named ones)
#                with its state: current, stale (a config or the source
#                data changed since the build), not built, invalid (cannot
#                be built as configured) or orphan (built, config gone),
#                plus build time, archive size, zooms, feature count (tile
#                count for a raster layer) and largest tile. Read only.
#                --list is the same.
#   --json       with --status: print JSON instead of a table.
#   --remove     delete the named layers' archives and manifest entries
#                and rewrite style.json. The configs in the layers dir are
#                not touched: delete them first (git rm), or the next full
#                build makes the layer again.
#
# Environment (defaults match the docker-compose mounts):
#   PIPELINE_INPUT_DIR   source data, read only        (default /data/raw)
#   PIPELINE_OUTPUT_DIR  .pmtiles, manifest.json and style.json
#                                                      (default /data/tiles)
#   PIPELINE_LAYERS_DIR  layer configs                 (default <pipeline>/layers)
#   TMPDIR               parent of the scratch dir     (default /tmp)
#
# A build attempts every layer; the exit status is 1 if any layer failed (or
# anything else went wrong), 2 for a usage error (including a layer with no
# config to build, or nothing built to remove), 0 otherwise.
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
# shellcheck source=lib/manifest.sh
source "${PIPELINE_ROOT}/lib/manifest.sh"
# shellcheck source=lib/display.sh
source "${PIPELINE_ROOT}/lib/display.sh"
# shellcheck source=lib/raster.sh
source "${PIPELINE_ROOT}/lib/raster.sh"
# shellcheck source=lib/status.sh
source "${PIPELINE_ROOT}/lib/status.sh"

PIPELINE_INPUT_DIR=${PIPELINE_INPUT_DIR:-/data/raw}
PIPELINE_OUTPUT_DIR=${PIPELINE_OUTPUT_DIR:-/data/tiles}
PIPELINE_LAYERS_DIR=${PIPELINE_LAYERS_DIR:-${PIPELINE_ROOT}/layers}

usage() {
  # The header comment block, skipping the shebang and shellcheck lines.
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# build_layer NAME CONFIG SCRATCH: run in a subshell, so `die` (and the
# config's variables) stay inside one layer.
build_layer() {
  local name=$1 config=$2 scratch=$3
  PIPELINE_LOG_PREFIX=$name

  load_layer_config "$config"

  local layer_scratch="${scratch}/${name}"
  mkdir -p "$layer_scratch"
  local started=$SECONDS
  local display="${layer_scratch}/display.json" report="${layer_scratch}/report.json"

  if [[ $LAYER_TYPE == raster ]]; then
    build_raster_layer
  else
    build_vector_layer
  fi

  manifest_update "$PIPELINE_OUTPUT_DIR" "$name" "$LAYER_TYPE" "$display" \
    "$(jq -c '.' "$report")" "$((SECONDS - started))"
}

# build_vector_layer: the vector steps of build_layer, whose locals (name,
# layer_scratch, display, report) it reads and writes.
build_vector_layer() {
  local normalised="${layer_scratch}/${name}.geojsonl"

  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" \
    "$LAYER_ENCODING" "$normalised" "${LAYER_FIELDS[@]}"

  local count
  count=$(wc -l <"$normalised")
  count=${count//[[:space:]]/}
  ((count > 0)) || die "no features after normalising $LAYER_INPUT"
  log_info "$count features"

  # The display config is checked before tiling, so a bad one costs nothing
  # and leaves the previous archive and manifest entry in place.
  resolve_display "$name" "${PIPELINE_LAYERS_DIR}/${name}.style.json" "$normalised" "$display"

  local sizes="${layer_scratch}/sizes.tsv" stats="${layer_scratch}/zoom_stats.json"
  feature_sizes "$normalised" "$LAYER_FEATURE_ID" "$sizes"

  build_tiles "$name" "$normalised" "$PIPELINE_OUTPUT_DIR" \
    "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$LAYER_FEATURE_ID" "$layer_scratch" \
    check_layer_tiles "${LAYER_TIPPECANOE_FLAGS[@]}"

  vector_report "$count" "$stats" "$LAYER_PROFILE" "$LAYER_MIN_VISIBLE_PX" >"$report"
}

# check_layer_tiles ARCHIVE: the drop guard, run by build_tiles from inside
# build_vector_layer, whose locals (name, sizes, count, stats) it reads.
check_layer_tiles() {
  drop_guard "$1" "$name" "$sizes" "$count" "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" \
    "$LAYER_MIN_VISIBLE_PX" "$stats"
}

# build_raster_layer: the raster steps of build_layer (lib/raster.sh), whose
# locals (name, layer_scratch, display, report) it reads and writes.
build_raster_layer() {
  # Checked first, as for a vector layer, so a bad config costs nothing. The
  # colour is not in the tiles (lib/raster.sh), only in the display block.
  resolve_display "$name" "${PIPELINE_LAYERS_DIR}/${name}.style.json" - "$display" raster

  build_raster_tiles "$name" "$LAYER_INPUT" "$LAYER_SOURCE_SRS" "$LAYER_NODATA" \
    "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$PIPELINE_OUTPUT_DIR" "$layer_scratch" "$report"
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
  require_tools jq
  for name in "$@"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if [[ ! -f "${PIPELINE_LAYERS_DIR}/${name}.env" && ! -f "${PIPELINE_OUTPUT_DIR}/${name}.pmtiles" ]] \
      && ! jq -e --arg n "$name" 'any(.layers[]?; .name == $n)' \
        "${PIPELINE_OUTPUT_DIR}/manifest.json" >/dev/null 2>&1; then
      log_error "no config or build for layer '$name'"
      return 2
    fi
  done

  local status
  status=$(layer_status_json "$PIPELINE_OUTPUT_DIR" "$PIPELINE_LAYERS_DIR" "$@")
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
  require_tools jq node
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
    if [[ ! -f "${PIPELINE_OUTPUT_DIR}/${name}.pmtiles" ]] \
      && ! jq -e --arg n "$name" 'any(.layers[]?; .name == $n)' "$manifest" >/dev/null 2>&1; then
      log_error "nothing built for layer '$name' in $PIPELINE_OUTPUT_DIR"
      return 2
    fi
  done
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  for name in "$@"; do
    manifest_remove "$PIPELINE_OUTPUT_DIR" "$name"
    rm -f "${PIPELINE_OUTPUT_DIR}/${name}.pmtiles"
    log_info "removed layer $name"
    if [[ -f "${PIPELINE_LAYERS_DIR}/${name}.env" ]]; then
      log_warn "${name}.env is still in ${PIPELINE_LAYERS_DIR}: delete its configs, or the next full build makes the layer again"
    fi
  done
  (write_style "$PIPELINE_OUTPUT_DIR")
}

main() {
  local arg mode=build json=0 layers=()
  for arg in "$@"; do
    case $arg in
      -h | --help)
        usage
        return 0
        ;;
      --status | --list | --remove)
        local wanted=status
        [[ $arg != --remove ]] || wanted=remove
        if [[ $mode != build && $mode != "$wanted" ]]; then
          log_error "--status and --remove cannot be used together"
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

  case $mode in
    status)
      status_main "$json" "${layers[@]}"
      return
      ;;
    remove)
      remove_main "${layers[@]}"
      return
      ;;
  esac

  require_tools gdal gdalwarp gdaldem gdalinfo ogr2ogr ogrinfo sqlite3 tippecanoe \
    tippecanoe-decode pmtiles jq node

  if ((${#layers[@]} == 0)); then
    local config
    for config in "${PIPELINE_LAYERS_DIR}"/*.env; do
      [[ -e $config ]] || continue
      config=${config##*/}
      layers+=("${config%.env}")
    done
    ((${#layers[@]} > 0)) || die "no layer configs in $PIPELINE_LAYERS_DIR"
  fi

  # Check every requested layer before building any of them.
  local name
  for name in "${layers[@]}"; do
    if ! layer_name_valid "$name"; then
      log_error "invalid layer name: $name"
      return 2
    fi
    if [[ ! -f "${PIPELINE_LAYERS_DIR}/${name}.env" ]]; then
      log_error "no config for layer '$name' in $PIPELINE_LAYERS_DIR"
      return 2
    fi
  done

  mkdir -p "$PIPELINE_OUTPUT_DIR" || die "cannot create $PIPELINE_OUTPUT_DIR"
  [[ -w $PIPELINE_OUTPUT_DIR ]] || die "output dir not writable: $PIPELINE_OUTPUT_DIR"

  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/pipeline.XXXXXX")
  # shellcheck disable=SC2064 # expand now: scratch is local to main.
  trap "rm -rf '${scratch}'" EXIT

  log_info "input $PIPELINE_INPUT_DIR, output $PIPELINE_OUTPUT_DIR, layers: ${layers[*]}"

  local failed=() status
  for name in "${layers[@]}"; do
    log_info "layer $name: start"
    # set +e around the subshell rather than `if ! (...)`: in a tested
    # context bash ignores `set -e` inside the subshell too.
    set +e
    (build_layer "$name" "${PIPELINE_LAYERS_DIR}/${name}.env" "$scratch")
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
  set +e
  (write_style "$PIPELINE_OUTPUT_DIR")
  local style_status=$?
  set -e

  if ((${#failed[@]} > 0)); then
    log_error "${#failed[@]} of ${#layers[@]} layer(s) failed: ${failed[*]}"
    return 1
  fi
  ((style_status == 0)) || return 1
  log_info "all ${#layers[@]} layer(s) built"
}

main "$@"
