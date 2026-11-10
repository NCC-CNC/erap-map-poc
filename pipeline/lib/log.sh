#!/usr/bin/env bash
# Logging helpers. Everything goes to stderr so stdout stays free for data.
# Set PIPELINE_LOG_PREFIX (for example to the layer name) to tag each line.

_log() {
  local level=$1
  shift
  printf '%s [%s]%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" \
    "${PIPELINE_LOG_PREFIX:+ ${PIPELINE_LOG_PREFIX}:}" "$*" >&2
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

# die MESSAGE: log an error and exit non-zero.
die() {
  log_error "$@"
  exit 1
}
