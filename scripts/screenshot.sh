#!/usr/bin/env bash
# Screenshot the web map with the tiles in data/tiles/, for checking a new or
# restyled layer by eye. Runs a private copy of the web image on a spare
# port and a pinned Playwright image on a private network, then removes
# both. A running compose stack, its ports and its natureconservancy/*
# images are not touched.
#
# Usage: scripts/screenshot.sh [options] VIEW...
#
#   VIEW                 zoom/lat/lon, MapLibre's URL hash order, for example
#                        6/55/-110. The layer's manifest entry has a centre
#                        (data/tiles/manifest.json, `center`: lon, lat, zoom).
#   -b, --basemap THEME  light, dark or all (default all): the basemaps the
#                        app offers (web/src/map/basemap.ts).
#   -o, --out DIR        output directory (default tmp/screenshots, which git
#                        ignores). Files are PREFIX-THEME-zZOOM_LAT_LON.png.
#   -n, --name PREFIX    file name prefix (default map).
#   -p, --port PORT      first host port to try for the web container
#                        (default 8090; the next 9 are tried if it is taken).
#   --image IMAGE        web image to run. Default: build web/ as
#                        erap-map-web:screenshot (cached after the first run).
#   --size WxH           viewport in CSS pixels (default 1280x800).
#   --wait SECONDS       settle time after the network goes quiet (default 3).
#   -h, --help           this help.
#
# Needs Docker and network access (the basemap tiles come from OpenFreeMap,
# and the Playwright client library from npm). Exit status: 0 on success, 1
# on failure, 2 for a usage error.
set -euo pipefail

# Git Bash: keep container paths such as /out as they are.
export MSYS_NO_PATHCONV=1

PLAYWRIGHT_VERSION=1.55.0
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble@sha256:b27e719ecbfef153e13fd24e8341736733bf2658b229677eb21ff57ff5d7fb29"
BUILD_TAG=erap-map-web:screenshot

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

log() { printf 'screenshot: %s\n' "$*" >&2; }

# host_path DIR: DIR as the Docker host sees it (a Windows path in Git Bash).
host_path() {
  (cd "$1" && { pwd -W 2>/dev/null || pwd; })
}

main() {
  local root
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

  local basemap=all out="${root}/tmp/screenshots" prefix=map port=8090 image="" size=1280x800 wait=3
  local views=()
  while (($# > 0)); do
    case $1 in
      -h | --help)
        usage
        return 0
        ;;
      -b | --basemap | -o | --out | -n | --name | -p | --port | --image | --size | --wait)
        if (($# < 2)); then
          log "$1 needs a value"
          return 2
        fi
        case $1 in
          -b | --basemap) basemap=$2 ;;
          -o | --out) out=$2 ;;
          -n | --name) prefix=$2 ;;
          -p | --port) port=$2 ;;
          --image) image=$2 ;;
          --size) size=$2 ;;
          --wait) wait=$2 ;;
        esac
        shift
        ;;
      -*)
        log "unknown option: $1"
        return 2
        ;;
      *) views+=("$1") ;;
    esac
    shift
  done

  local themes
  case $basemap in
    all) themes="light dark" ;;
    light | dark) themes=$basemap ;;
    *)
      log "unknown basemap: $basemap (light, dark or all)"
      return 2
      ;;
  esac
  if ((${#views[@]} == 0)); then
    log "no views given (zoom/lat/lon, for example 6/55/-110)"
    return 2
  fi
  local view
  for view in "${views[@]}"; do
    if ! [[ $view =~ ^[0-9]+([.][0-9]+)?/-?[0-9]+([.][0-9]+)?/-?[0-9]+([.][0-9]+)?$ ]]; then
      log "bad view: $view (zoom/lat/lon, for example 6/55/-110)"
      return 2
    fi
  done
  [[ $prefix =~ ^[A-Za-z0-9_-]+$ ]] || { log "bad prefix: $prefix"; return 2; }
  [[ $port =~ ^[0-9]+$ ]] || { log "bad port: $port"; return 2; }
  [[ $size =~ ^([0-9]+)x([0-9]+)$ ]] || { log "bad size: $size (WxH)"; return 2; }
  local width=${BASH_REMATCH[1]} height=${BASH_REMATCH[2]}
  [[ $wait =~ ^[0-9]+([.][0-9]+)?$ ]] || { log "bad wait: $wait"; return 2; }

  [[ -s ${root}/data/tiles/manifest.json ]] \
    || { log "no data/tiles/manifest.json: run the pipeline first"; return 1; }
  mkdir -p "$out"

  if [[ -z $image ]]; then
    log "building ${BUILD_TAG} from web/"
    docker build -q -t "$BUILD_TAG" "$(host_path "${root}/web")" >/dev/null
    image=$BUILD_TAG
  fi

  # Names unique to this run, removed on exit.
  local run_id="erap-screenshot-$$"
  local network=$run_id web="${run_id}-web"
  # shellcheck disable=SC2064 # expand now: the names are local.
  trap "docker rm -f '${web}' >/dev/null 2>&1 || true; docker network rm '${network}' >/dev/null 2>&1 || true" EXIT
  docker network create "$network" >/dev/null

  # A taken port fails `docker run`; try the next one.
  local tiles try started="" err=""
  tiles=$(host_path "${root}/data/tiles")
  for ((try = port; try < port + 10; try++)); do
    if err=$(docker run -d --name "$web" --network "$network" --network-alias web \
      -p "127.0.0.1:${try}:8080" --read-only --tmpfs /tmp \
      -v "${tiles}:/srv/tiles:ro" "$image" 2>&1 >/dev/null); then
      started=$try
      break
    fi
    docker rm -f "$web" >/dev/null 2>&1 || true
  done
  [[ -n $started ]] || { log "cannot start the web container on ports ${port}-$((port + 9)): ${err}"; return 1; }
  log "web app at http://127.0.0.1:${started}/ (until this script exits)"

  local ok=""
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${started}/tiles/manifest.json" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  [[ -n $ok ]] || { docker logs "$web" >&2 || true; log "web app did not start"; return 1; }

  local scripts
  scripts=$(host_path "${root}/scripts")
  # Chromium needs more shared memory than Docker's 64 MB default.
  docker run --rm --init --shm-size=1g --network "$network" \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e NPM_CONFIG_UPDATE_NOTIFIER=false \
    -v "${scripts}/screenshot.cjs:/opt/screenshot.cjs:ro" \
    -v "$(host_path "$out"):/out" \
    -e SHOT_BASE=http://web:8080/ -e "SHOT_VIEWS=${views[*]}" -e "SHOT_THEMES=${themes}" \
    -e "SHOT_PREFIX=${prefix}" -e "SHOT_WIDTH=${width}" -e "SHOT_HEIGHT=${height}" \
    -e "SHOT_WAIT_MS=$(awk -v s="$wait" 'BEGIN { printf "%d", s * 1000 }')" \
    "$PLAYWRIGHT_IMAGE" sh -c "mkdir -p /tmp/shot && cd /tmp/shot \
      && npm install --no-save --no-audit --no-fund --loglevel=error playwright-core@${PLAYWRIGHT_VERSION} >/dev/null \
      && cp /opt/screenshot.cjs . && node screenshot.cjs"
  log "screenshots in ${out}"
}

main "$@"
