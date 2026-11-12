#!/usr/bin/env bash
# First-time setup on Windows 11 (Git Bash, Docker Desktop). Run from Git
# Bash in the repo:
#
#   scripts/setup.sh [--check]     check this machine, change nothing (default)
#   scripts/setup.sh --init        check, write .env, build, start the map
#
# --check reports each item as ok, warn or FAIL with a one-line fix: the
# shell, Git, line endings, Docker Desktop (installed, on the PATH, engine
# running, Linux containers, WSL 2, Compose), Docker memory and CPUs, free
# disk, .env, RAW_DIR and the ports. It installs, starts and writes nothing.
#
# --init runs the same checks, stops at the first failure, then:
#   1. creates .env from .env.example if there is none, asking for the data
#      folder (RAW_DIR) and the ports (Enter keeps the default). An existing
#      .env is kept; it changes only for values given as flags, after a yes
#      (or --yes), with a dated copy kept as .env.bak.<time>;
#   2. builds the pipeline image (the first time takes about 5 minutes) and
#      every configured layer (pipeline/layers/) that is not built yet or is
#      stale. Layers whose source data is not in RAW_DIR are skipped, with a
#      note. A raster layer takes tens of minutes; Ctrl+C is safe, and a
#      rerun carries on with the layers still to build;
#   3. builds and starts the map, waits until it responds and prints its URL.
# It is safe to rerun and never deletes anything.
#
# Options (--init):
#   --raw-dir PATH     source data folder for RAW_DIR, for example
#                      C:/data/ERAP_play_data (read only to the pipeline)
#   --web-port PORT    host port for the map (WEB_PORT, default 8080)
#   --dev-port PORT    host port for the Vite dev server (WEB_DEV_PORT,
#                      default 5173)
#   -y, --yes          no questions: take the defaults and flag values, and
#                      update an existing .env with the flag values
#   --skip-layers      build no layers: only the images and the map
#   -h, --help         this help
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE, from the shell or .env, pass
# through to docker compose. Exit status: 0 when nothing failed, 1 when a
# check or step failed, 2 for a usage error.

# Thresholds. A full-Canada raster build (ADR 0008) runs gdalwarp with a 2 GB
# block cache and a 1 GB warp buffer, writes a few GB of scratch inside the
# container and a 2 to 4 GB archive to data/tiles/.
MIN_DOCKER_MEM_GB=8
MIN_DOCKER_CPUS=4
MIN_REPO_DISK_GB=10
MIN_DOCKER_DISK_GB=20
MIN_DISK_FAIL_GB=3
# Docker Desktop 4.x needs WSL 2.1.5 or later.
MIN_WSL_VERSION=2.1.5
DEFAULT_WEB_PORT=8080
DEFAULT_DEV_PORT=5173
# Settings in .env.example, plus the compose ones a user may add.
KNOWN_ENV_KEYS=" WEB_PORT WEB_DEV_PORT PIPELINE_UID PIPELINE_GID VITE_USE_POLLING RAW_DIR COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PROFILES "

FAILS=0
WARNS=0
ASSUME_YES=0
SKIP_LAYERS=0
DOCKER_OK=0
DOCKER_WSL2=0
DOCKER_DESKTOP=0
DOCKER_ROOT_DIR=""
ROOT=""

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

# report STATUS LABEL MESSAGE [FIX]: one result line, and the fix under it.
report() {
  local status=$1 label=$2 message=$3 fix=${4:-}
  case $status in
    fail)
      FAILS=$((FAILS + 1))
      status=FAIL
      ;;
    warn) WARNS=$((WARNS + 1)) ;;
  esac
  printf '  %-5s %-14s %s\n' "$status" "$label" "$message"
  if [[ -n $fix ]]; then
    printf '  %-5s %-14s fix: %s\n' "" "" "$fix"
  fi
}

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

# os_kind: gitbash, wsl, linux or other.
os_kind() {
  case $(uname -s 2>/dev/null) in
    MINGW* | MSYS*) echo gitbash ;;
    Linux)
      if grep -qi microsoft "${SETUP_PROC_VERSION:-/proc/version}" 2>/dev/null; then
        echo wsl
      else
        echo linux
      fi
      ;;
    *) echo other ;;
  esac
}

# unix_path PATH: a Windows path (C:\x or C:/x) as this shell sees it.
unix_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s\n' "$1"
  fi
}

# display_path PATH: a path the way Windows users write it (C:/x).
display_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

# version_ge A B: true when version A >= B (dotted numbers).
version_ge() {
  local IFS=.
  local -a a b
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  local i x y
  for ((i = 0; i < 4; i++)); do
    x=${a[i]:-0} y=${b[i]:-0}
    x=${x//[^0-9]/} y=${y//[^0-9]/}
    ((10#${x:-0} > 10#${y:-0})) && return 0
    ((10#${x:-0} < 10#${y:-0})) && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# .env reading and writing

# env_file_value KEY: the last value of KEY in .env (quotes removed); fails
# when it is not set there.
env_file_value() {
  local file="${ROOT}/.env"
  [[ -f $file ]] || return 1
  local value
  value=$(tr -d '\r' <"$file" | awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "=" { sub("^[[:space:]]*" key "=", ""); v = $0; found = 1 }
    END { if (found) print v; else exit 1 }') || return 1
  value=${value%"${value##*[![:space:]]}"}
  if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
    value=${BASH_REMATCH[1]}
  fi
  printf '%s\n' "$value"
}

# setting KEY DEFAULT: what compose will use: the shell, then .env, then
# the default.
setting() {
  local key=$1 default=$2
  if [[ -n ${!key+x} ]]; then
    printf '%s\n' "${!key}"
  elif env_file_value "$key"; then
    :
  else
    printf '%s\n' "$default"
  fi
}

# env_line KEY VALUE: KEY=VALUE, quoted when the value needs it.
env_line() {
  if [[ $2 =~ [[:space:]\#\'] ]]; then
    printf '%s="%s"\n' "$1" "$2"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# set_env_value FILE KEY VALUE: set KEY on its existing line (dropping any
# repeats), or on the commented `# KEY=` example line, or on a new last
# line. Rewrites FILE via a temp file.
set_env_value() {
  local file=$1 key=$2 mode=append
  if grep -qE "^[[:space:]]*${key}=" "$file"; then
    mode=replace
  elif grep -qE "^#[[:space:]]*${key}=" "$file"; then
    mode=uncomment
  fi
  SET_ENV_LINE=$(env_line "$2" "$3") awk -v key="$key" -v mode="$mode" '
    BEGIN { line = ENVIRON["SET_ENV_LINE"] }
    mode == "replace" && $0 ~ "^[[:space:]]*" key "=" { if (!done) print line; done = 1; next }
    mode == "uncomment" && !done && $0 ~ "^#[[:space:]]*" key "=" { print line; done = 1; next }
    { print }
    END { if (mode == "append") print line }' "$file" >"${file}.tmp.$$"
  mv "${file}.tmp.$$" "$file"
}

# normalise_dir PATH: forward slashes; a Git Bash /c/x path as C:/x.
normalise_dir() {
  local p=${1//\\//}
  if [[ $p =~ ^/([a-zA-Z])(/.*)?$ ]] && command -v cygpath >/dev/null 2>&1; then
    p=$(cygpath -m "$p")
  fi
  printf '%s\n' "${p%/}"
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

# ---------------------------------------------------------------------------
# Checks: system

check_shell() {
  case $(os_kind) in
    gitbash) report ok "Shell" "Git Bash (${MSYSTEM:-MSYS})" ;;
    wsl) report fail "Shell" "WSL bash, not Git Bash" \
      "open Git Bash (Start menu, Git Bash) and rerun scripts/setup.sh there; in PowerShell, 'bash' may be WSL" ;;
    linux) report warn "Shell" "Linux, not Windows: only Windows 11 with Git Bash is supported" \
      "the checks still run; Docker Desktop and WSL items do not apply" ;;
    *) report warn "Shell" "$(uname -s 2>/dev/null || echo unknown) is not supported (Windows 11 with Git Bash is)" ;;
  esac
}

check_git() {
  local version
  if ! version=$(git --version 2>/dev/null); then
    report fail "Git" "git not found" "install Git for Windows (from IT or git-scm.com), then open a new Git Bash window"
    return
  fi
  report ok "Git" "$version"
  if [[ -f ${ROOT}/docker-compose.yml && -d ${ROOT}/pipeline && -d ${ROOT}/web ]]; then
    report ok "Repo" "$(display_path "$ROOT")"
  else
    report fail "Repo" "$(display_path "$ROOT") is not the erap-map-poc repo" \
      "clone it: git clone https://github.com/NCC-CNC/erap-map-poc.git, then run erap-map-poc/scripts/setup.sh"
  fi
}

# crlf_files: shell scripts and layer configs with CRLF line endings.
crlf_files() {
  local dir
  for dir in pipeline/bin pipeline/lib pipeline/layers pipeline/tests scripts; do
    [[ -d ${ROOT}/${dir} ]] || continue
    find "${ROOT}/${dir}" -type f \( -name '*.sh' -o -name '*.bats' -o -name '*.env' \) \
      -exec grep -l $'\r' {} + 2>/dev/null || true
  done
}

check_line_endings() {
  local bad count first
  bad=$(crlf_files)
  if [[ -z $bad ]]; then
    report ok "Line endings" "scripts are LF"
    return
  fi
  count=$(wc -l <<<"$bad")
  first=${bad%%$'\n'*}
  report fail "Line endings" "${count} script(s) have Windows (CRLF) line endings, for example ${first#"${ROOT}/"}" \
    "the pipeline breaks on these; clone the repo again with Git for Windows (.gitattributes keeps scripts LF) and do not copy files in from elsewhere"
}

# docker_desktop_dir: where Docker Desktop installs itself.
docker_desktop_dir() {
  printf '%s/Docker/Docker\n' "$(unix_path "${PROGRAMFILES:-C:\\Program Files}")"
}

check_docker() {
  local os
  os=$(os_kind)
  if ! command -v docker >/dev/null 2>&1; then
    if [[ -d $(docker_desktop_dir) ]]; then
      report fail "Docker" "Docker Desktop is installed but docker is not on the PATH of this shell" \
        "close every Git Bash window and open a new one (sign out and in if that is not enough), then rerun"
    elif [[ $os == gitbash ]]; then
      report fail "Docker" "Docker Desktop is not installed" \
        "request Docker Desktop from IT (installing it needs admin rights). After it is installed: restart Windows, start Docker Desktop and wait for 'Engine running', open a new Git Bash window, rerun scripts/setup.sh"
    else
      report fail "Docker" "docker not found" "install Docker with Compose v2, then rerun"
    fi
    docker_skipped
    return
  fi

  local info err
  err=$(mktemp)
  if ! info=$(timeout 30 docker info --format \
    '{{.OSType}}|{{.ServerVersion}}|{{.MemTotal}}|{{.NCPU}}|{{.KernelVersion}}|{{.OperatingSystem}}|{{.DockerRootDir}}' 2>"$err") \
    || [[ -z $info || $info != *"|"* ]]; then
    if grep -qiE 'access is denied|permission denied' "$err"; then
      report fail "Docker engine" "this account cannot reach the Docker engine (access denied)" \
        "ask IT to add your account to the docker-users group, then sign out of Windows and in again"
    else
      report fail "Docker engine" "not running (or still starting)" \
        "start Docker Desktop from the Start menu, wait until it shows 'Engine running', then rerun"
    fi
    rm -f "$err"
    docker_skipped
    return
  fi
  rm -f "$err"

  local ostype version mem cpus kernel osname
  IFS='|' read -r ostype version mem cpus kernel osname DOCKER_ROOT_DIR <<<"$info"
  [[ $osname == *"Docker Desktop"* ]] && DOCKER_DESKTOP=1
  [[ $kernel == *WSL2* ]] && DOCKER_WSL2=1
  if [[ $ostype != linux ]]; then
    report fail "Docker engine" "Docker Desktop is in Windows containers mode" \
      "right-click the Docker icon by the clock and choose 'Switch to Linux containers', then rerun"
    docker_skipped
    return
  fi
  DOCKER_OK=1
  report ok "Docker engine" "${version}, Linux containers (${osname})"

  if ((DOCKER_DESKTOP)); then
    if ((DOCKER_WSL2)); then
      report ok "Backend" "WSL 2"
    else
      report warn "Backend" "Hyper-V, not WSL 2" \
        "Docker Desktop Settings, General: turn on 'Use the WSL 2 based engine' (faster file access)"
    fi
  fi

  local compose
  if ! compose=$(docker compose version --short 2>/dev/null) || [[ -z $compose ]]; then
    report fail "Compose" "docker compose (v2) not found" "update Docker Desktop (ask IT); it includes Compose v2"
  elif version_ge "${compose#v}" 2; then
    report ok "Compose" "v${compose#v}"
  else
    report fail "Compose" "v${compose#v} is too old (v2 or later)" "update Docker Desktop (ask IT)"
  fi

  check_docker_resources "$mem" "$cpus"
}

# docker_skipped: say which checks wait for a working Docker.
docker_skipped() {
  report skip "Docker" "Compose, memory, CPUs and Docker's disk are checked once Docker works"
}

# resources_fix: where Docker's memory and CPUs are set.
resources_fix() {
  if ((DOCKER_WSL2)); then
    printf '%s' "on the WSL 2 backend these come from %USERPROFILE%\\.wslconfig: under [wsl2] set for example memory=12GB and processors=8, run 'wsl --shutdown' in PowerShell, then restart Docker Desktop"
  else
    printf '%s' "Docker Desktop Settings, Resources, Advanced: raise Memory and CPUs, then Apply and restart"
  fi
}

check_docker_resources() {
  local mem=$1 cpus=$2 gb
  gb=$(awk -v b="${mem:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }')
  if awk -v g="$gb" -v m="$MIN_DOCKER_MEM_GB" 'BEGIN { exit !(g + 0.5 < m) }'; then
    report warn "Docker memory" "${gb} GB, below the ${MIN_DOCKER_MEM_GB} GB suggested for raster layers" "$(resources_fix)"
  else
    report ok "Docker memory" "${gb} GB"
  fi
  if ((${cpus:-0} < MIN_DOCKER_CPUS)); then
    report warn "Docker CPUs" "${cpus:-0}, below the ${MIN_DOCKER_CPUS} suggested for raster layers" "$(resources_fix)"
  else
    report ok "Docker CPUs" "$cpus"
  fi
}

# Checks WSL only where it is used: Git Bash on Windows, with wsl.exe.
check_wsl() {
  [[ $(os_kind) == gitbash ]] || return 0
  if ! command -v wsl.exe >/dev/null 2>&1; then
    report warn "WSL" "cannot check (wsl.exe not found)" \
      "Docker Desktop needs WSL 2: if Docker does not start, ask IT to install or update WSL"
    return
  fi
  local out version
  # wsl.exe writes UTF-16; drop the NUL bytes. An old in-box WSL has no
  # --version.
  if ! out=$(timeout 20 wsl.exe --version 2>&1 | tr -d '\0\r') \
    || ! version=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$out" | head -n 1) || [[ -z $version ]]; then
    report warn "WSL" "WSL 2 is missing or out of date (no 'wsl --version')" \
      "run 'wsl --update' in PowerShell (if that is refused, ask IT), then restart Docker Desktop"
  elif version_ge "$version" "$MIN_WSL_VERSION"; then
    report ok "WSL" "$version"
  else
    report warn "WSL" "${version}, older than the ${MIN_WSL_VERSION} Docker Desktop needs" \
      "run 'wsl --update' in PowerShell (if that is refused, ask IT), then restart Docker Desktop"
  fi
}

# docker_data_dir: the folder holding Docker's disk image, or nothing.
docker_data_dir() {
  local dir="" settings
  if ((DOCKER_DESKTOP)) || [[ $(os_kind) == gitbash ]]; then
    settings="$(unix_path "${APPDATA:-}")/Docker/settings-store.json"
    if [[ -n ${APPDATA:-} && -f $settings ]]; then
      dir=$(sed -n 's/.*"CustomWslDistroDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" | head -n 1)
      dir=${dir//\\\\/\\}
      if [[ -n $dir ]]; then
        dir=$(unix_path "$dir")
      fi
    fi
    if [[ -z $dir && -n ${LOCALAPPDATA:-} ]]; then
      dir="$(unix_path "$LOCALAPPDATA")/Docker/wsl"
    fi
  else
    dir=$DOCKER_ROOT_DIR
  fi
  if [[ -n $dir && -d $dir ]]; then
    printf '%s\n' "$dir"
  fi
}

# disk_free PATH: "<free GB> <filesystem> <mount point>".
disk_free() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%d %s %s\n", $4 / 1048576, $1, $6 }'
}

disk_report() {
  local label=$1 free=$2 fs=$3 min=$4 what=$5
  if ((free < MIN_DISK_FAIL_GB)); then
    report fail "$label" "${fs%:}: ${free} GB free (${what})" "free some space on ${fs} (at least ${min} GB suggested)"
  elif ((free < min)); then
    report warn "$label" "${fs%:}: ${free} GB free, below the ${min} GB suggested (${what})" \
      "free some space; raster layers need a few GB each, and Docker images and build cache several more"
  else
    report ok "$label" "${fs%:}: ${free} GB free (${what})"
  fi
}

check_disk() {
  local repo_free repo_fs repo_mount dir docker_free docker_fs docker_mount
  read -r repo_free repo_fs repo_mount < <(disk_free "$ROOT") || true
  if [[ -z ${repo_free:-} ]]; then
    report warn "Disk" "cannot read free space for the repo"
    return
  fi
  dir=$(docker_data_dir)
  if [[ -n $dir ]]; then
    read -r docker_free docker_fs docker_mount < <(disk_free "$dir") || true
  fi
  if [[ -z ${docker_free:-} ]]; then
    disk_report "Disk" "$repo_free" "$repo_fs" "$MIN_REPO_DISK_GB" "repo"
    if ((DOCKER_OK)); then
      report warn "Docker disk" "cannot find Docker's data folder to check its free space"
    fi
  elif [[ $docker_mount == "$repo_mount" ]]; then
    disk_report "Disk" "$repo_free" "$repo_fs" $((MIN_REPO_DISK_GB + MIN_DOCKER_DISK_GB)) "repo and Docker data"
  else
    disk_report "Disk" "$repo_free" "$repo_fs" "$MIN_REPO_DISK_GB" "repo"
    disk_report "Docker disk" "$docker_free" "$docker_fs" "$MIN_DOCKER_DISK_GB" "Docker data"
  fi
}

run_system_checks() {
  check_shell
  check_git
  check_line_endings
  check_docker
  check_wsl
  check_disk
}

# ---------------------------------------------------------------------------
# Checks: settings

check_env_file() {
  local file="${ROOT}/.env"
  if [[ ! -f $file ]]; then
    report warn ".env" "none yet; every setting has a default" "scripts/setup.sh --init writes one (or copy .env.example to .env)"
    return
  fi
  local n=0 line key bad="" unknown="" ports=""
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      key=${BASH_REMATCH[1]}
      [[ $KNOWN_ENV_KEYS == *" ${key} "* ]] || unknown+=" ${key}"
    else
      bad+=" ${n}"
    fi
  done <"$file"
  for key in WEB_PORT WEB_DEV_PORT; do
    line=$(env_file_value "$key") || continue
    valid_port "$line" || ports+=" ${key}=${line}"
  done
  if [[ -n $bad ]]; then
    report fail ".env" "line(s)${bad} are not KEY=VALUE or a # comment" "fix or remove those lines in .env (.env.example shows the format)"
  elif [[ -n $ports ]]; then
    report fail ".env" "not a port number:${ports}" "use a number from 1 to 65535 in .env"
  elif grep -q $'\r' "$file"; then
    report warn ".env" "has Windows (CRLF) line endings" "save it with LF line endings (most editors have the option)"
  elif [[ -n $unknown ]]; then
    report warn ".env" "unknown setting(s):${unknown}" "check the spelling against .env.example"
  else
    report ok ".env" "present"
  fi
}

check_raw_dir() {
  local value dir real root_real
  value=$(setting RAW_DIR "")
  if [[ -z $value ]]; then
    report warn "RAW_DIR" "not set: the pipeline reads data/raw/ in the repo" \
      "set RAW_DIR in .env to the folder holding the source data, outside the repo (scripts/setup.sh --init --raw-dir PATH)"
    return
  fi
  dir=$(unix_path "$value")
  [[ $dir == /* ]] || dir="${ROOT}/${dir#./}"
  if [[ ! -e $dir ]]; then
    report fail "RAW_DIR" "${value}: folder not found" \
      "check the path in .env (forward slashes, for example C:/data/ERAP_play_data) and that the drive is connected"
    return
  fi
  if [[ ! -d $dir ]]; then
    report fail "RAW_DIR" "${value}: not a folder" "point RAW_DIR in .env at the folder holding the data"
    return
  fi
  if [[ ! -r $dir || ! -x $dir ]] || ! ls "$dir" >/dev/null 2>&1; then
    report fail "RAW_DIR" "${value}: cannot read the folder" "check your access to it (ask the folder's owner or IT)"
    return
  fi
  real=$(cd "$dir" && pwd -P)
  root_real=$(cd "$ROOT" && pwd -P)
  if [[ $real == "$root_real" || $real == "$root_real"/* ]] && [[ $real != "$root_real/data/raw" && $real != "$root_real"/data/raw/* ]]; then
    report warn "RAW_DIR" "${value} is inside the repo, outside data/raw/" \
      "keep data in a folder outside the repo so it cannot be committed by mistake"
    return
  fi
  if [[ -z $(ls -A "$dir" 2>/dev/null) ]]; then
    report warn "RAW_DIR" "${value} is empty" "check the path; the real layers read their source files from here"
    return
  fi
  report ok "RAW_DIR" "${value} (read only to the pipeline)"
}

# port_in_use PORT: something on this machine accepts connections on it.
port_in_use() {
  timeout 2 bash -c ": </dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# port_is_ours SERVICE PORT: this compose project's SERVICE publishes PORT.
port_is_ours() {
  ((DOCKER_OK)) || return 1
  local ours theirs
  ours=$(docker compose --profile dev ps -q "$1" 2>/dev/null) || return 1
  [[ -n $ours ]] || return 1
  theirs=$(docker ps -q --no-trunc --filter "publish=$2" 2>/dev/null) || return 1
  [[ -n $theirs && $theirs == *"$ours"* ]]
}

# check_port LABEL KEY DEFAULT SERVICE LEVEL
check_port() {
  local label=$1 key=$2 default=$3 service=$4 level=$5 port
  port=$(setting "$key" "$default")
  if ! valid_port "$port"; then
    report fail "$label" "${key}=${port} is not a port number" "use a number from 1 to 65535"
  elif ! port_in_use "$port"; then
    report ok "$label" "${port} is free"
  elif port_is_ours "$service" "$port"; then
    report ok "$label" "${port}, in use by this map's ${service} container"
  else
    report "$level" "$label" "${port} is in use by another program" \
      "set ${key} to a free port in .env (or --${service/web-dev/dev}-port with --init; for example ${key}=$((port + 1)))"
  fi
}

run_config_checks() {
  check_env_file
  check_raw_dir
  check_port "Map port" WEB_PORT "$DEFAULT_WEB_PORT" web fail
  check_port "Dev port" WEB_DEV_PORT "$DEFAULT_DEV_PORT" web-dev warn
}

summary() {
  say ""
  if ((FAILS > 0)); then
    say "${FAILS} failed, ${WARNS} warning(s). Fix the FAIL items above, then rerun scripts/setup.sh."
  elif ((WARNS > 0)); then
    say "No failures, ${WARNS} warning(s)."
  else
    say "All checks passed."
  fi
}

# ---------------------------------------------------------------------------
# --init

is_interactive() { [[ -t 0 ]]; }

# ask QUESTION DEFAULT: the answer (the default for Enter, and when nobody
# is there to answer).
ask() {
  local answer
  if ((ASSUME_YES)) || ! is_interactive; then
    printf '%s\n' "$2"
    return
  fi
  read -r -p "$1 [$2]: " answer || answer=""
  printf '%s\n' "${answer:-$2}"
}

# confirm QUESTION: yes with --yes, no when nobody is there to answer.
confirm() {
  local answer
  ((ASSUME_YES)) && return 0
  is_interactive || return 1
  read -r -p "$1 [y/N]: " answer || return 1
  [[ $answer =~ ^[Yy] ]]
}

# ask_port QUESTION DEFAULT: a valid port, asking until one is given.
ask_port() {
  local value
  while :; do
    value=$(ask "$1" "$2")
    if valid_port "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    say "  not a port number: ${value}" >&2
    if ((ASSUME_YES)) || ! is_interactive; then
      return 1
    fi
  done
}

# ask_raw_dir DEFAULT: a data folder, or empty for data/raw/.
ask_raw_dir() {
  local value
  while :; do
    value=$(ask "Folder holding your source data, for example C:/data/ERAP_play_data (blank: data/raw/ in the repo)" "$1")
    value=$(normalise_dir "$value")
    if [[ -z $value || -d $(unix_path "$value") ]] || ((ASSUME_YES)) || ! is_interactive; then
      printf '%s\n' "$value"
      return 0
    fi
    say "  folder not found: ${value}" >&2
    if confirm "Use it anyway?"; then
      printf '%s\n' "$value"
      return 0
    fi
  done
}

# configure_env: create .env, or update it with the flag values.
configure_env() {
  local file="${ROOT}/.env"
  if [[ ! -f $file ]]; then
    step "Creating .env (Enter keeps the default in brackets)"
    local raw web dev
    raw=$(ask_raw_dir "${OPT_RAW_DIR:-}")
    web=$(ask_port "Port for the map (WEB_PORT)" "${OPT_WEB_PORT:-$DEFAULT_WEB_PORT}") || return 1
    dev=$(ask_port "Port for the dev server (WEB_DEV_PORT)" "${OPT_DEV_PORT:-$DEFAULT_DEV_PORT}") || return 1
    cp "${ROOT}/.env.example" "${file}.new.$$"
    [[ -n $raw ]] && set_env_value "${file}.new.$$" RAW_DIR "$raw"
    [[ $web != "$DEFAULT_WEB_PORT" ]] && set_env_value "${file}.new.$$" WEB_PORT "$web"
    [[ $dev != "$DEFAULT_DEV_PORT" ]] && set_env_value "${file}.new.$$" WEB_DEV_PORT "$dev"
    mv "${file}.new.$$" "$file"
    say "Wrote .env${raw:+ (RAW_DIR=${raw})}. Edit it any time; .env.example describes each setting."
    return 0
  fi

  local -a keys=() values=()
  local key value current i
  [[ -n ${OPT_RAW_DIR+x} ]] && keys+=(RAW_DIR) && values+=("$(normalise_dir "$OPT_RAW_DIR")")
  [[ -n ${OPT_WEB_PORT+x} ]] && keys+=(WEB_PORT) && values+=("$OPT_WEB_PORT")
  [[ -n ${OPT_DEV_PORT+x} ]] && keys+=(WEB_DEV_PORT) && values+=("$OPT_DEV_PORT")
  local -a change=()
  for i in "${!keys[@]}"; do
    key=${keys[i]} value=${values[i]}
    current=$(env_file_value "$key") || current=""
    [[ $current == "$value" ]] || change+=("$i")
  done
  if ((${#change[@]} == 0)); then
    say ""
    say "Keeping the existing .env."
    return 0
  fi
  step "Updating .env"
  for i in "${change[@]}"; do
    current=$(env_file_value "${keys[i]}") || current="(not set)"
    say "  ${keys[i]}: ${current} -> ${values[i]}"
  done
  if ! confirm "Update .env? A copy of the current one is kept"; then
    say "Keeping the existing .env unchanged (rerun with --yes to update it)."
    return 0
  fi
  local backup
  backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$file" "$backup"
  cp "$file" "${file}.new.$$"
  for i in "${change[@]}"; do
    set_env_value "${file}.new.$$" "${keys[i]}" "${values[i]}"
  done
  mv "${file}.new.$$" "$file"
  say "Updated .env; the previous one is ${backup#"${ROOT}/"}."
}

# layer_states: one "NAME<TAB>STATE" line per configured layer, from the
# pipeline's --status (which also builds the pipeline image when needed).
layer_states() {
  docker compose run --rm --build -T --entrypoint sh pipeline -c \
    'run.sh --status --json | jq -r ".layers[] | select(.configured) | [.name, .state] | @tsv"'
}

# join_names NAME...: "a, b and c".
join_names() {
  local out=$1
  shift
  while (($# > 1)); do
    out+=", $1"
    shift
  done
  (($# == 0)) || out+=" and $1"
  printf '%s\n' "$out"
}

# build_layers: build every configured layer that is not built or is stale;
# skip those that cannot be built (source data not in RAW_DIR). Returns 2
# when the pipeline image or the layer check fails, 1 when a layer build
# fails.
build_layers() {
  step "Building the pipeline image and checking the layers (the first time takes about 5 minutes)"
  local states
  if ! states=$(layer_states); then
    say ""
    say "The pipeline image did not build, or its layer check failed; the messages above say why."
    return 2
  fi
  local name state
  local -a todo=() current=() invalid=()
  while IFS=$'\t' read -r name state; do
    [[ -n $name ]] || continue
    case $state in
      current) current+=("$name") ;;
      invalid) invalid+=("$name") ;;
      *) todo+=("$name") ;;
    esac
  done <<<"${states//$'\r'/}"

  if ((${#current[@]} + ${#invalid[@]} + ${#todo[@]} == 0)); then
    say "No layers are configured in pipeline/layers/, so there is nothing to build; the map shows the basemap only."
    say "README.md (Adding a layer) explains how to add one."
    return 0
  fi
  if ((${#current[@]} > 0)); then
    say "Already built and up to date: $(join_names "${current[@]}")."
  fi
  if ((${#invalid[@]} > 0)); then
    say "Skipped, cannot be built yet: $(join_names "${invalid[@]}"). Usually the source data is not in RAW_DIR;"
    say "'docker compose run --rm pipeline --status' says why for each. Fix it, then rerun scripts/setup.sh --init."
  fi
  if ((${#todo[@]} == 0)); then
    return 0
  fi
  if ((SKIP_LAYERS)); then
    say "Not building $(join_names "${todo[@]}") (--skip-layers). Later: docker compose run --rm pipeline ${todo[*]}"
    return 0
  fi
  step "Building $(join_names "${todo[@]}")"
  say "A raster layer takes tens of minutes. Ctrl+C stops safely; rerun scripts/setup.sh --init to carry on."
  if ! docker compose run --rm pipeline "${todo[@]}"; then
    say ""
    say "A layer build failed; the messages above say why ('docker compose run --rm pipeline --status' lists what is built)."
    return 1
  fi
}

# wait_for_web PORT: the map answers within about 60 seconds.
wait_for_web() {
  local i
  for ((i = 0; i < 30; i++)); do
    if curl -fsS -o /dev/null "http://localhost:$1/" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

init() {
  step "Checking this machine"
  run_system_checks
  if ((FAILS > 0)); then
    summary
    return 1
  fi
  configure_env || {
    say "Not a valid port; nothing was built."
    return 1
  }
  step "Checking the settings"
  run_config_checks
  if ((FAILS > 0)); then
    summary
    return 1
  fi

  # A failed layer still leaves the map to start; a failed image does not.
  local layers=0
  build_layers || layers=$?
  if ((layers == 2)); then
    return 1
  fi

  local port
  port=$(setting WEB_PORT "$DEFAULT_WEB_PORT")
  step "Building and starting the map"
  if ! docker compose up -d --build web; then
    say ""
    say "The map did not start; the messages above say why."
    return 1
  fi
  say "Waiting for the map to respond..."
  if ! wait_for_web "$port"; then
    docker compose logs --tail 30 web || true
    say ""
    say "The map did not respond on port ${port}; its log is above."
    return 1
  fi

  say ""
  if ((layers)); then
    say "The map is at http://localhost:${port}, but a layer build failed (see above)."
  else
    say "Done. The map is at http://localhost:${port} (in Git Bash, 'start http://localhost:${port}' opens it)."
  fi
  say ""
  say "Next:"
  say "  docker compose run --rm pipeline --status    what is built and what is stale"
  say "  docker compose run --rm pipeline NAME        build or rebuild one layer"
  say "  docker compose down                          stop the map; 'docker compose up -d web' starts it again"
  say "README.md has the rest (Usage, Adding a layer)."
  if ((WARNS > 0)); then
    say ""
    say "${WARNS} warning(s) above; the map works, but read them before building raster layers."
  fi
  ((layers == 0))
}

main() {
  set -euo pipefail
  local mode=check
  ASSUME_YES=0 SKIP_LAYERS=0
  unset OPT_RAW_DIR OPT_WEB_PORT OPT_DEV_PORT
  while (($# > 0)); do
    case $1 in
      -h | --help)
        usage
        return 0
        ;;
      --check) mode=check ;;
      --init) mode=init ;;
      -y | --yes) ASSUME_YES=1 ;;
      --skip-layers) SKIP_LAYERS=1 ;;
      --raw-dir | --web-port | --dev-port)
        if (($# < 2)); then
          say "setup: $1 needs a value" >&2
          return 2
        fi
        case $1 in
          --raw-dir) OPT_RAW_DIR=$2 ;;
          --web-port) OPT_WEB_PORT=$2 ;;
          --dev-port) OPT_DEV_PORT=$2 ;;
        esac
        shift
        ;;
      --raw-dir=* | --web-port=* | --dev-port=*)
        set -- "${1%%=*}" "${1#*=}" "${@:2}"
        continue
        ;;
      *)
        say "setup: unknown option: $1 (see --help)" >&2
        return 2
        ;;
    esac
    shift
  done
  local opt
  for opt in OPT_WEB_PORT OPT_DEV_PORT; do
    if [[ -n ${!opt+x} ]] && ! valid_port "${!opt}"; then
      say "setup: not a port number: ${!opt}" >&2
      return 2
    fi
  done
  if [[ $mode == check && -n ${OPT_RAW_DIR+x}${OPT_WEB_PORT+x}${OPT_DEV_PORT+x}${SKIP_LAYERS#0} ]]; then
    say "setup: --raw-dir, --web-port, --dev-port and --skip-layers go with --init" >&2
    return 2
  fi

  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  cd "$ROOT"

  if [[ $mode == init ]]; then
    init
    return
  fi
  say "ERAP Map setup check (read only; nothing is changed)"
  say ""
  run_system_checks
  run_config_checks
  summary
  if ((FAILS > 0)); then
    return 1
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
