#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
# Pipeline entry point: build vector tiles for every layer config in
# pipeline/layers/, or only the layers named on the command line.
#
# Usage: run.sh [-h|--help] [layer ...]
#
# Environment (defaults match the docker-compose mounts):
#   PIPELINE_INPUT_DIR   source data, read only        (default /data/raw)
#   PIPELINE_OUTPUT_DIR  .pmtiles and manifest.json    (default /data/tiles)
#   PIPELINE_LAYERS_DIR  layer configs                 (default <pipeline>/layers)
#   TMPDIR               parent of the scratch dir     (default /tmp)
#
# Every layer is attempted; the exit status is 1 if any layer failed, 2 for a
# usage error, 0 otherwise.
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
  local normalised="${layer_scratch}/${name}.geojsonl"

  normalise "$LAYER_INPUT" "$LAYER_SOURCE_LAYER" "$LAYER_SOURCE_SRS" \
    "$LAYER_ENCODING" "$normalised" "${LAYER_FIELDS[@]}"

  local count
  count=$(wc -l <"$normalised")
  count=${count//[[:space:]]/}
  ((count > 0)) || die "no features after normalising $LAYER_INPUT"
  log_info "$count features"

  local sizes="${layer_scratch}/sizes.tsv" stats="${layer_scratch}/zoom_stats.json"
  feature_sizes "$normalised" "$LAYER_FEATURE_ID" "$sizes"

  build_tiles "$name" "$normalised" "$PIPELINE_OUTPUT_DIR" \
    "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" "$LAYER_FEATURE_ID" "$layer_scratch" \
    check_layer_tiles "${LAYER_TIPPECANOE_FLAGS[@]}"

  manifest_update "$PIPELINE_OUTPUT_DIR" "$name" "$count" "$stats" \
    "$LAYER_PROFILE" "$LAYER_MIN_VISIBLE_PX"
}

# check_layer_tiles ARCHIVE: the drop guard, run by build_tiles from inside
# build_layer, whose locals (name, sizes, count, stats) it reads.
check_layer_tiles() {
  drop_guard "$1" "$name" "$sizes" "$count" "$LAYER_MIN_ZOOM" "$LAYER_MAX_ZOOM" \
    "$LAYER_MIN_VISIBLE_PX" "$stats"
}

main() {
  local arg layers=()
  for arg in "$@"; do
    case $arg in
      -h | --help)
        usage
        return 0
        ;;
      -*)
        log_error "unknown option: $arg"
        usage >&2
        return 2
        ;;
      *) layers+=("$arg") ;;
    esac
  done

  local tool
  for tool in gdal ogr2ogr ogrinfo tippecanoe tippecanoe-decode pmtiles jq; do
    command -v "$tool" >/dev/null || die "required tool not found: $tool"
  done

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

  if ((${#failed[@]} > 0)); then
    log_error "${#failed[@]} of ${#layers[@]} layer(s) failed: ${failed[*]}"
    return 1
  fi
  log_info "all ${#layers[@]} layer(s) built"
}

main "$@"
