#!/usr/bin/env bats
# Tests for scripts/setup.sh, with no Docker, WSL or Windows: each test runs
# a copy of the script in a fake repo under BATS_TEST_TMPDIR, with stub
# docker, wsl.exe, git, uname, df, curl and sleep commands first on the PATH.
# The stubs log their arguments to $STUB_LOG and answer from STUB_*
# variables. Run in the pipeline test image (it has bats), with the repo
# mounted read only:
#   docker build --target test -t erap-map-pipeline:test pipeline
#   docker run --rm -v "$repo":/repo:ro erap-map-pipeline:test /repo/scripts/tests
#
# Each @test runs in a subshell, so its exports are meant to stay local
# (SC2030, SC2031), and the functions a test redefines are called by the
# sourced script (SC2329).
# shellcheck disable=SC2030,SC2031,SC2329

setup() {
  SRC=$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  REPO=$T/repo
  mkdir -p "$REPO"/scripts "$REPO"/pipeline/{bin,lib,layers,tests} "$REPO"/web "$REPO"/data/raw
  cp "$SRC/scripts/setup.sh" "$REPO/scripts/setup.sh"
  cp "$SRC/.env.example" "$REPO/.env.example"
  printf 'name: erap-map\n' >"$REPO/docker-compose.yml"
  printf '#!/usr/bin/env bash\necho ok\n' >"$REPO/pipeline/bin/run.sh"
  touch "$REPO/data/raw/.gitkeep"
  SETUP=$REPO/scripts/setup.sh

  # A data folder outside the repo.
  DATA=$T/data
  mkdir -p "$DATA"
  touch "$DATA/forest.tif"

  export STUB_LOG=$T/calls.log
  : >"$STUB_LOG"
  STUB=$T/bin
  mkdir -p "$STUB"
  stub docker <<'EOF'
echo "docker $*" >>"$STUB_LOG"
case "$*" in
  info*)
    if [[ -n ${STUB_DOCKER_INFO_ERR:-} ]]; then
      echo "$STUB_DOCKER_INFO_ERR" >&2
      exit 1
    fi
    echo "${STUB_DOCKER_INFO:-linux|29.7.2|25199009792|16|6.6.87.2-microsoft-standard-WSL2|Docker Desktop|/var/lib/docker}"
    ;;
  "compose version"*) echo "${STUB_COMPOSE_VERSION-2.39.1}" ;;
  "compose --profile dev ps -q"*) echo "${STUB_OUR_CONTAINER:-}" ;;
  "ps -q --no-trunc --filter"*) echo "${STUB_PORT_CONTAINER:-}" ;;
  # The layer check: NAME<TAB>STATE lines, like the jq in setup.sh prints.
  "compose run --rm --build -T --entrypoint sh pipeline -c"*)
    printf '%b' "${STUB_LAYER_STATES-lakes\tnot built\n}"
    exit "${STUB_STATUS_EXIT:-0}"
    ;;
  "compose run"*) exit "${STUB_BUILD_EXIT:-0}" ;;
  "compose up"*) exit "${STUB_UP_EXIT:-0}" ;;
esac
exit 0
EOF
  stub wsl.exe <<'EOF'
echo "wsl.exe $*" >>"$STUB_LOG"
# UTF-16 like the real one: a NUL after each character.
printf 'WSL version: %s\nKernel version: 6.6.87.2-1\n' "${STUB_WSL_VERSION:-2.6.1.0}" | sed 's/./&\x00/g'
exit "${STUB_WSL_EXIT:-0}"
EOF
  stub git <<'EOF'
echo "git version 2.47.1.windows.1"
EOF
  stub uname <<'EOF'
echo "${STUB_UNAME:-MINGW64_NT-10.0-26200}"
EOF
  stub df <<'EOF'
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
case $2 in
  *localappdata* | *dockerdata*) echo "D: 1 1 ${STUB_DF_DOCKER_KB:-104857600} 1% ${STUB_DF_DOCKER_MOUNT:-/d}" ;;
  *) echo "C: 1 1 ${STUB_DF_REPO_KB:-104857600} 1% /c" ;;
esac
EOF
  stub curl <<'EOF'
echo "curl $*" >>"$STUB_LOG"
exit "${STUB_CURL_EXIT:-0}"
EOF
  stub sleep <<'EOF'
exit 0
EOF
  export PATH="$STUB:$PATH"
  export PROGRAMFILES=$T/pf APPDATA=$T/appdata LOCALAPPDATA=$T/localappdata
  mkdir -p "$LOCALAPPDATA/Docker/wsl"
  export MSYSTEM=MINGW64
  unset RAW_DIR WEB_PORT WEB_DEV_PORT COMPOSE_PROJECT_NAME COMPOSE_FILE
}

# stub NAME: an executable NAME in the stub dir, its body from stdin.
stub() {
  { echo '#!/usr/bin/env bash'; cat; } >"$STUB/$1"
  chmod +x "$STUB/$1"
}

# line LABEL: the result line for LABEL from the last run, from its status on.
line() {
  local l
  for l in "${lines[@]}"; do
    if [[ $l =~ ^\ \ (ok|warn|FAIL|skip)\ +"$1"\  ]]; then
      echo "${l#  }"
      return 0
    fi
  done
  return 1
}

# refute COMMAND...: fail the test when COMMAND succeeds (a bare `!` does
# not, under bats' set -e).
refute() {
  ! "$@"
}

# load_setup: the script's functions in this shell (main does not run), so
# a test can call one or redefine one, such as port_in_use.
load_setup() {
  # shellcheck source=scripts/setup.sh
  source "$SETUP"
}

# ---------------------------------------------------------------------------
# Usage

@test "--help prints the usage" {
  run bash "$SETUP" --help
  [ "$status" -eq 0 ]
  [[ $output == *"scripts/setup.sh --init"* ]]
  [[ $output == *"--raw-dir PATH"* ]]
}

@test "usage errors exit 2" {
  run bash "$SETUP" --frobnicate
  [ "$status" -eq 2 ]
  run bash "$SETUP" --init --web-port eighty
  [ "$status" -eq 2 ]
  run bash "$SETUP" --init --raw-dir
  [ "$status" -eq 2 ]
  run bash "$SETUP" --check --raw-dir "$DATA"
  [ "$status" -eq 2 ]
  run bash "$SETUP" --skip-layers
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ]
}

# ---------------------------------------------------------------------------
# --check

@test "--check on a good machine passes and changes nothing" {
  printf 'RAW_DIR=%s\n' "$DATA" >"$REPO/.env"
  before=$(ls -A "$REPO")
  run bash "$SETUP" --check
  [ "$status" -eq 0 ]
  [[ $output != *FAIL* && $output != *warn* ]]
  [[ $(line Shell) == *"Git Bash (MINGW64)"* ]]
  [[ $(line "Docker engine") == *"29.7.2, Linux containers (Docker Desktop)"* ]]
  [[ $(line Backend) == *"WSL 2"* ]]
  [[ $(line Compose) == *v2.39.1* ]]
  [[ $(line "Docker memory") == *"23.5 GB"* ]]
  [[ $(line WSL) == *2.6.1* ]]
  [[ $(line Disk) == *"C: 100 GB free (repo)"* ]]
  [[ $(line "Docker disk") == *"D: 100 GB free (Docker data)"* ]]
  [[ $(line RAW_DIR) == ok*"$DATA"* ]]
  [[ $(line "Map port") == *"8080 is free"* ]]
  [[ $output == *"All checks passed."* ]]
  [ "$(ls -A "$REPO")" = "$before" ]
  refute grep -qE 'docker compose (run|up|build)' "$STUB_LOG"
}

@test "no arguments means --check" {
  run bash "$SETUP"
  [ "$status" -eq 0 ]
  [[ $output == *"setup check (read only"* ]]
}

@test "Docker not installed: ask IT, skip the Docker checks" {
  rm "$STUB/docker"
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Docker) == FAIL*"Docker Desktop is not installed"* ]]
  [[ $output == *"request Docker Desktop from IT"* ]]
  [[ $output == *"restart Windows, start Docker Desktop"* ]]
  [[ $(line Docker) == FAIL* ]]
  [[ $output == *"skip  Docker"*"checked once Docker works"* ]]
  refute line Compose
  refute line "Docker memory"
}

@test "Docker Desktop installed but not on the PATH: open a new Git Bash" {
  rm "$STUB/docker"
  mkdir -p "$PROGRAMFILES/Docker/Docker"
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Docker) == FAIL*"not on the PATH"* ]]
  [[ $output == *"open a new one"* ]]
}

@test "Docker engine not running: start Docker Desktop" {
  export STUB_DOCKER_INFO_ERR="error during connect: open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified."
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line "Docker engine") == FAIL*"not running"* ]]
  [[ $output == *"start Docker Desktop from the Start menu"* ]]
  [[ $output == *"skip  Docker"* ]]
  refute line Compose
}

@test "Docker access denied: docker-users group" {
  export STUB_DOCKER_INFO_ERR="permission denied while trying to connect: Access is denied."
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line "Docker engine") == FAIL*"access denied"* ]]
  [[ $output == *"docker-users group"* ]]
}

@test "Windows containers mode fails" {
  export STUB_DOCKER_INFO="windows|29.7.2|25199009792|16|10.0 26200|Docker Desktop|C:\\ProgramData\\docker"
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line "Docker engine") == FAIL*"Windows containers"* ]]
  [[ $output == *"Switch to Linux containers"* ]]
}

@test "Hyper-V backend, low memory and few CPUs warn, with where to change them" {
  export STUB_DOCKER_INFO="linux|29.7.2|4294967296|2|6.6.32-linuxkit|Docker Desktop|/var/lib/docker"
  run bash "$SETUP" --check
  [ "$status" -eq 0 ]
  [[ $(line Backend) == warn*Hyper-V* ]]
  [[ $(line "Docker memory") == warn*"4.0 GB, below the 8 GB"* ]]
  [[ $(line "Docker CPUs") == warn*"2, below the 4"* ]]
  [[ $output == *"Settings, Resources"* ]]
}

@test "low memory on WSL 2 points at .wslconfig" {
  export STUB_DOCKER_INFO="linux|29.7.2|4294967296|16|6.6.87.2-microsoft-standard-WSL2|Docker Desktop|/var/lib/docker"
  run bash "$SETUP" --check
  [ "$status" -eq 0 ]
  [[ $(line "Docker memory") == warn* ]]
  [[ $output == *".wslconfig"*"wsl --shutdown"* ]]
}

@test "Compose missing or v1 fails" {
  export STUB_COMPOSE_VERSION=""
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Compose) == FAIL*"not found"* ]]
  export STUB_COMPOSE_VERSION=1.29.2
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Compose) == FAIL*"too old"* ]]
}

@test "WSL missing, old or unreadable warns" {
  export STUB_WSL_EXIT=1
  run bash "$SETUP" --check
  [ "$status" -eq 0 ]
  [[ $(line WSL) == warn*"missing or out of date"* ]]
  [[ $output == *"wsl --update"* ]]

  export STUB_WSL_EXIT=0 STUB_WSL_VERSION=2.0.9.0
  run bash "$SETUP" --check
  [[ $(line WSL) == warn*"2.0.9, older than the 2.1.5"* ]]

  rm "$STUB/wsl.exe"
  run bash "$SETUP" --check
  [[ $(line WSL) == warn*"cannot check"* ]]
}

@test "WSL bash fails the shell check; plain Linux warns and skips WSL" {
  echo "Linux version 6.6.87.2-microsoft-standard-WSL2" >"$T/proc_version"
  export STUB_UNAME=Linux SETUP_PROC_VERSION=$T/proc_version
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Shell) == FAIL*"WSL bash"* ]]
  [[ $output == *"open Git Bash"* ]]

  echo "Linux version 6.8.0-generic" >"$T/proc_version"
  run bash "$SETUP" --check
  [ "$status" -eq 0 ]
  [[ $(line Shell) == warn*"only Windows 11 with Git Bash"* ]]
  refute line WSL
  refute grep -q wsl.exe "$STUB_LOG"
}

@test "a script with CRLF line endings fails" {
  printf '#!/usr/bin/env bash\r\nset -euo pipefail\r\n' >"$REPO/pipeline/lib/broken.sh"
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line "Line endings") == FAIL*"1 script(s)"*"pipeline/lib/broken.sh"* ]]
  [[ $output == *"clone the repo again"* ]]
}

@test "not the repo fails" {
  rm "$REPO/docker-compose.yml"
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Repo) == FAIL*"not the erap-map-poc repo"* ]]
}

@test "free disk: one line for a shared drive, warn when low, fail when nearly full" {
  export STUB_DF_DOCKER_MOUNT=/c
  run bash "$SETUP" --check
  [[ $(line Disk) == ok*"(repo and Docker data)"* ]]
  refute line "Docker disk"

  export STUB_DF_DOCKER_MOUNT=/d STUB_DF_DOCKER_KB=$((15 * 1048576)) STUB_DF_REPO_KB=$((1 * 1048576))
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line Disk) == FAIL*"C: 1 GB free"* ]]
  [[ $(line "Docker disk") == warn*"15 GB free, below the 20 GB"* ]]
}

@test "Docker's disk follows a custom location in Docker Desktop's settings" {
  rmdir "$LOCALAPPDATA/Docker/wsl"
  mkdir -p "$APPDATA/Docker" "$T/dockerdata"
  printf '{"CustomWslDistroDir": "%s", "Other": 1}\n' "$T/dockerdata" >"$APPDATA/Docker/settings-store.json"
  export STUB_DF_DOCKER_KB=$((50 * 1048576))
  run bash "$SETUP" --check
  [[ $(line "Docker disk") == ok*"D: 50 GB free"* ]]
}

@test ".env problems: bad line and bad port fail, CRLF and unknown keys warn" {
  printf 'WEB_PORT=8080\nthis is not a setting\n' >"$REPO/.env"
  run bash "$SETUP" --check
  [[ $(line .env) == FAIL*"line(s) 2 are not KEY=VALUE"* ]]

  printf 'WEB_PORT=80a\n' >"$REPO/.env"
  run bash "$SETUP" --check
  [[ $(line .env) == FAIL*"WEB_PORT=80a"* ]]
  [[ $(line "Map port") == FAIL*"not a port number"* ]]

  printf 'WEB_PORT=8081\r\n' >"$REPO/.env"
  run bash "$SETUP" --check
  [[ $(line .env) == warn*CRLF* ]]
  [[ $(line "Map port") == *"8081 is free"* ]]

  printf 'WEB_PROT=8081\n' >"$REPO/.env"
  run bash "$SETUP" --check
  [[ $(line .env) == warn*"unknown setting(s): WEB_PROT"* ]]
}

@test "RAW_DIR: unset warns, missing fails, inside the repo or empty warns" {
  run bash "$SETUP" --check
  [[ $(line RAW_DIR) == warn*"not set"* ]]

  printf 'RAW_DIR="%s/nowhere"\n' "$T" >"$REPO/.env"
  run bash "$SETUP" --check
  [ "$status" -eq 1 ]
  [[ $(line RAW_DIR) == FAIL*"$T/nowhere: folder not found"* ]]

  mkdir -p "$REPO/mydata"
  touch "$REPO/mydata/x.gpkg"
  printf 'RAW_DIR=./mydata\n' >"$REPO/.env"
  run bash "$SETUP" --check
  [[ $(line RAW_DIR) == warn*"inside the repo"* ]]

  printf 'RAW_DIR=./data/raw\n' >"$REPO/.env"
  run bash "$SETUP" --check
  [[ $(line RAW_DIR) == ok* ]]

  mkdir -p "$T/empty"
  run env RAW_DIR="$T/empty" bash "$SETUP" --check
  [[ $(line RAW_DIR) == warn*"is empty"* ]]
}

@test "the shell's RAW_DIR wins over .env, like compose" {
  printf 'RAW_DIR=%s/nowhere\n' "$T" >"$REPO/.env"
  run env RAW_DIR="$DATA" bash "$SETUP" --check
  [ "$status" -eq 0 ]
  [[ $(line RAW_DIR) == ok*"$DATA"* ]]
}

@test "a busy map port fails unless this map holds it" {
  load_setup
  port_in_use() { [[ $1 == 8080 ]]; }
  run main --check
  [ "$status" -eq 1 ]
  [[ $(line "Map port") == FAIL*"8080 is in use by another program"* ]]
  [[ $output == *"--web-port with --init"* ]]

  export STUB_OUR_CONTAINER=abc123 STUB_PORT_CONTAINER=abc123
  run main --check
  [ "$status" -eq 0 ]
  [[ $(line "Map port") == ok*"in use by this map's web container"* ]]
}

@test "a busy dev port only warns" {
  load_setup
  port_in_use() { [[ $1 == 5173 ]]; }
  run main --check
  [ "$status" -eq 0 ]
  [[ $(line "Dev port") == warn*"5173 is in use"* ]]
  [[ $output == *"--dev-port with --init"* ]]
}

# ---------------------------------------------------------------------------
# .env helpers

@test "set_env_value replaces, uncomments, appends and quotes" {
  load_setup
  f=$T/env
  printf '# WEB_PORT=8080\nRAW_DIR=a\nRAW_DIR=b\n' >"$f"
  set_env_value "$f" WEB_PORT 8081
  set_env_value "$f" RAW_DIR "C:/My Data/ERAP"
  set_env_value "$f" WEB_DEV_PORT 5174
  run cat "$f"
  [ "${lines[0]}" = "WEB_PORT=8081" ]
  [ "${lines[1]}" = 'RAW_DIR="C:/My Data/ERAP"' ]
  [ "${lines[2]}" = "WEB_DEV_PORT=5174" ]
  [ "${#lines[@]}" -eq 3 ]

  # shellcheck disable=SC2034 # read by env_file_value
  ROOT=$T
  cp "$f" "$T/.env"
  run env_file_value RAW_DIR
  [ "$output" = "C:/My Data/ERAP" ]
  run env_file_value PIPELINE_UID
  [ "$status" -eq 1 ]
}

@test "normalise_dir turns backslashes into forward slashes" {
  load_setup
  [ "$(normalise_dir 'C:\data\ERAP_play_data')" = "C:/data/ERAP_play_data" ]
  [ "$(normalise_dir "C:/data/ERAP_play_data/")" = "C:/data/ERAP_play_data" ]
}

@test "version_ge compares dotted versions" {
  load_setup
  version_ge 2.6.1 2.1.5
  version_ge 2.1.5 2.1.5
  version_ge 10.0 9.9
  refute version_ge 2.0.9 2.1.5
  refute version_ge 1.29.2 2
}

# ---------------------------------------------------------------------------
# --init

@test "--init with flags writes .env, builds the layers and starts the map" {
  run bash "$SETUP" --init --yes --raw-dir "$DATA" --web-port 8085
  [ "$status" -eq 0 ]
  grep -qx "RAW_DIR=$DATA" "$REPO/.env"
  grep -qx "WEB_PORT=8085" "$REPO/.env"
  grep -qx "# WEB_DEV_PORT=5173" "$REPO/.env"
  grep -q "docker compose run --rm --build -T --entrypoint sh pipeline -c run.sh --status --json" "$STUB_LOG"
  grep -qx "docker compose run --rm pipeline lakes" "$STUB_LOG"
  grep -qx "docker compose up -d --build web" "$STUB_LOG"
  grep -q "curl .*http://localhost:8085/" "$STUB_LOG"
  [[ $output == *"Done. The map is at http://localhost:8085"* ]]
}

@test "--init builds only layers not built or stale, and skips those it cannot build" {
  export STUB_LAYER_STATES='forest\tsource missing\nlakes\tcurrent\nroads\tstale\nparks\tnot built\nwetlands\tinvalid\ndunes\tdisabled\n'
  run bash "$SETUP" --init --yes
  [ "$status" -eq 0 ]
  grep -qx "docker compose run --rm pipeline roads parks" "$STUB_LOG"
  [[ $output == *"Already built and up to date: lakes."* ]]
  [[ $output == *"Skipped, cannot be built yet: forest and wetlands."* ]]
  [[ $output == *"Left out by your map config (map.config.json): dunes."* ]]
  [[ $output == *"Building roads and parks"* ]]
}

@test "--init with nothing to build starts the map without a layer build" {
  export STUB_LAYER_STATES='forest\tinvalid\nagriculture\tinvalid\n'
  run bash "$SETUP" --init --yes
  [ "$status" -eq 0 ]
  [[ $output == *"Skipped, cannot be built yet: forest and agriculture."* ]]
  [ "$(grep -c 'compose run' "$STUB_LOG")" -eq 1 ]
  grep -qx "docker compose up -d --build web" "$STUB_LOG"

  export STUB_LAYER_STATES=''
  run bash "$SETUP" --init --yes
  [ "$status" -eq 0 ]
  [[ $output == *"No layers are configured"* ]]
  [ "$(grep -c 'compose run' "$STUB_LOG")" -eq 2 ]
}

@test "--init --skip-layers builds no layers" {
  run bash "$SETUP" --init --yes --skip-layers
  [ "$status" -eq 0 ]
  [[ $output == *"Not building lakes (--skip-layers)"* ]]
  refute grep -qx "docker compose run --rm pipeline lakes" "$STUB_LOG"
  grep -qx "docker compose up -d --build web" "$STUB_LOG"
}

@test "join_names lists names in plain English" {
  load_setup
  [ "$(join_names a)" = "a" ]
  [ "$(join_names a b)" = "a and b" ]
  [ "$(join_names a b c)" = "a, b and c" ]
}

@test "--init without a terminal takes the defaults" {
  run bash "$SETUP" --init </dev/null
  [ "$status" -eq 0 ]
  cmp -s "$REPO/.env" "$REPO/.env.example"
  [[ $output == *"http://localhost:8080"* ]]
}

@test "--init asks for the data folder and ports" {
  load_setup
  is_interactive() { return 0; }
  run main --init <<<"$(printf '%s\n%s\n%s\n' "$DATA" 9o 8090)"
  [ "$status" -eq 0 ]
  [[ $output == *"not a port number: 9o"* ]]
  grep -qx "RAW_DIR=$DATA" "$REPO/.env"
  grep -qx "WEB_PORT=8090" "$REPO/.env"
  grep -qx "# WEB_DEV_PORT=5173" "$REPO/.env"
}

@test "--init asks before using a data folder that does not exist" {
  load_setup
  is_interactive() { return 0; }
  run main --init <<<"$(printf '%s\nn\n%s\n\n\n' "$T/typo" "$DATA")"
  [ "$status" -eq 0 ]
  [[ $output == *"folder not found: $T/typo"* ]]
  grep -qx "RAW_DIR=$DATA" "$REPO/.env"
}

@test "--init keeps an existing .env, and is safe to rerun" {
  printf 'RAW_DIR=%s\nWEB_PORT=8085\n' "$DATA" >"$REPO/.env"
  cp "$REPO/.env" "$T/before"
  run bash "$SETUP" --init </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"Keeping the existing .env."* ]]
  cmp -s "$REPO/.env" "$T/before"
  run bash "$SETUP" --init --yes --web-port 8085
  [ "$status" -eq 0 ]
  cmp -s "$REPO/.env" "$T/before"
  [ -z "$(compgen -G "$REPO/.env.bak.*")" ]
  [ "$(grep -c 'compose up -d --build web' "$STUB_LOG")" -eq 2 ]
}

@test "--init changes an existing .env only after a yes, keeping a copy" {
  printf 'RAW_DIR=%s/old\n' "$T" >"$REPO/.env"
  mkdir -p "$T/old"
  touch "$T/old/x.tif"
  cp "$REPO/.env" "$T/before"
  run bash "$SETUP" --init --raw-dir "$DATA" </dev/null
  [[ $output == *"RAW_DIR: $T/old -> $DATA"* ]]
  [[ $output == *"Keeping the existing .env unchanged"* ]]
  cmp -s "$REPO/.env" "$T/before"

  run bash "$SETUP" --init --yes --raw-dir "$DATA"
  [ "$status" -eq 0 ]
  grep -qx "RAW_DIR=$DATA" "$REPO/.env"
  backup=$(compgen -G "$REPO/.env.bak.*")
  cmp -s "$backup" "$T/before"
}

@test "--init stops before writing anything when Docker is not running" {
  export STUB_DOCKER_INFO_ERR="error during connect"
  run bash "$SETUP" --init --yes --raw-dir "$DATA"
  [ "$status" -eq 1 ]
  [ ! -e "$REPO/.env" ]
  refute grep -qE 'docker compose (run|up)' "$STUB_LOG"
  [[ $output == *"Fix the FAIL items above"* ]]
}

@test "--init stops before building when RAW_DIR is missing" {
  run bash "$SETUP" --init --yes --raw-dir "$T/nowhere"
  [ "$status" -eq 1 ]
  [[ $(line RAW_DIR) == FAIL*"folder not found"* ]]
  refute grep -qE 'docker compose (run|up)' "$STUB_LOG"
}

@test "--init stops when the pipeline image does not build" {
  export STUB_STATUS_EXIT=1 STUB_LAYER_STATES=''
  run bash "$SETUP" --init --yes
  [ "$status" -eq 1 ]
  [[ $output == *"The pipeline image did not build"* ]]
  refute grep -q "compose up" "$STUB_LOG"
}

@test "--init still starts the map after a failed layer build, and fails" {
  export STUB_BUILD_EXIT=1
  run bash "$SETUP" --init --yes
  [ "$status" -eq 1 ]
  [[ $output == *"A layer build failed"* ]]
  grep -qx "docker compose up -d --build web" "$STUB_LOG"
  [[ $output == *"The map is at http://localhost:8080, but a layer build failed"* ]]
}

@test "--init reports a map that does not start or answer" {
  export STUB_UP_EXIT=1
  run bash "$SETUP" --init --yes
  [ "$status" -eq 1 ]
  [[ $output == *"The map did not start"* ]]

  export STUB_UP_EXIT=0 STUB_CURL_EXIT=7
  run bash "$SETUP" --init --yes
  [ "$status" -eq 1 ]
  [[ $output == *"did not respond on port 8080"* ]]
  grep -q "docker compose logs --tail 30 web" "$STUB_LOG"
}
