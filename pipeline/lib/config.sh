#!/usr/bin/env bash
# Layer config loading and validation.
#
# A layer config is a bash file, pipeline/layers/<layer>.env, sourced in a
# subshell per layer. The layer name is the file name without `.env`.
# Variables (see layers/sample.env for a worked example):
#
#   LAYER_INPUT             required. Source dataset path. Relative paths are
#                           resolved against PIPELINE_INPUT_DIR.
#   LAYER_SOURCE_LAYER      optional. Layer inside the source dataset; defaults
#                           to the first layer.
#   LAYER_FIELDS            required array. Attributes to keep, as `src` or
#                           `src:dest` to rename. Everything else is dropped.
#   LAYER_FEATURE_ID        required. Output attribute holding a stable integer
#                           id; written as the vector tile feature id.
#   LAYER_MIN_ZOOM          required. Minimum tile zoom.
#   LAYER_MAX_ZOOM          required. Maximum tile zoom.
#   LAYER_TIPPECANOE_FLAGS  optional array. Extra tippecanoe flags.

# layer_name_valid NAME: layer names become file names and URL paths, so keep
# them to lower case letters, digits, `_` and `-`.
layer_name_valid() {
  [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# load_layer_config FILE: source FILE and check the required variables. Call
# only inside the per-layer subshell so one layer's settings cannot leak into
# the next.
load_layer_config() {
  local file=$1
  [[ -r $file ]] || die "layer config not readable: $file"

  # Reset, then set by the config. Some are read only by bin/run.sh.
  LAYER_INPUT=""
  # shellcheck disable=SC2034
  LAYER_SOURCE_LAYER=""
  LAYER_FIELDS=()
  LAYER_FEATURE_ID=""
  LAYER_MIN_ZOOM=""
  LAYER_MAX_ZOOM=""
  # shellcheck disable=SC2034
  LAYER_TIPPECANOE_FLAGS=()

  # shellcheck source=/dev/null
  source "$file"

  [[ -n $LAYER_INPUT ]] || die "LAYER_INPUT is not set in $file"
  ((${#LAYER_FIELDS[@]} > 0)) || die "LAYER_FIELDS is empty in $file"
  [[ -n $LAYER_FEATURE_ID ]] || die "LAYER_FEATURE_ID is not set in $file"
  [[ $LAYER_MIN_ZOOM =~ ^[0-9]+$ ]] || die "LAYER_MIN_ZOOM must be an integer in $file"
  [[ $LAYER_MAX_ZOOM =~ ^[0-9]+$ ]] || die "LAYER_MAX_ZOOM must be an integer in $file"
  ((LAYER_MIN_ZOOM <= LAYER_MAX_ZOOM)) || die "LAYER_MIN_ZOOM > LAYER_MAX_ZOOM in $file"

  local field dest found=0
  for field in "${LAYER_FIELDS[@]}"; do
    dest=${field#*:}
    [[ $dest == "$LAYER_FEATURE_ID" ]] && found=1
  done
  ((found)) || die "LAYER_FEATURE_ID '$LAYER_FEATURE_ID' is not in LAYER_FIELDS in $file"

  if [[ $LAYER_INPUT != /* ]]; then
    LAYER_INPUT="${PIPELINE_INPUT_DIR}/${LAYER_INPUT}"
  fi
}
