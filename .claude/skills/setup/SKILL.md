---
name: setup
description: Set up the ERAP map on a new Windows machine, or check one that is not working - runs scripts/setup.sh to check Git Bash, Docker Desktop (running, Linux containers, WSL 2, memory, CPUs, disk), .env, RAW_DIR and the ports, explains each failure with Windows steps, helps write .env, builds the images and layers, starts the map and opens it. Use when asked to set up, install or get started with the map, after cloning the repo, or why Docker or the setup is not working.
---

# Set up the map

All logic is in `scripts/setup.sh` (`--help` lists every option); this
skill only runs it and explains its output. Run from the repo root in Git
Bash, never PowerShell or WSL. If the repo is not cloned yet:
`git clone https://github.com/NCC-CNC/erap-map-poc.git && cd erap-map-poc`.

## 1. Check

```sh
scripts/setup.sh --check
```

Read only. Each line is `ok`, `warn`, `FAIL` or `skip`, with a `fix:`
line under it. Explain each `FAIL` and `warn` in plain language, using
the fix the script gives. Common ones on Windows:

- Shell: WSL bash or PowerShell. Open Git Bash from the Start menu.
- Docker not installed: Docker Desktop comes from IT (admin rights). Never
  try to install it; help the user word the request.
- Docker engine not running: start Docker Desktop, wait for "Engine
  running". Access denied: IT adds the account to `docker-users`, then
  sign out and in.
- WSL old or missing: `wsl --update` in PowerShell (IT if refused), then
  restart Docker Desktop.
- Docker memory or CPUs low (warn): only raster builds need more; on WSL 2
  they come from `%USERPROFILE%\.wslconfig`, as the fix line says.
- Port in use: pick another with `--web-port` or `--dev-port` below.

Fix every `FAIL` before going on; ask before changing anything outside
the repo.

## 2. Settings

Ask the user where their source data lives (a folder outside the repo,
for example `C:/data/ERAP_play_data`), or leave it blank if they have
none yet. Ask about ports only if the check said one is busy.

## 3. Init

```sh
scripts/setup.sh --init --yes --raw-dir 'C:/path/to/data' [--web-port N] [--skip-layers]
```

Leave out `--raw-dir` if there is no data folder. An existing `.env` is
kept unless a flag changes a value (it keeps a `.env.bak.*` copy). Say
first that the first run takes about 5 minutes plus the layers, and that
a raster layer takes tens of minutes; offer `--skip-layers` to start the
map without building layers. Run it in the background and report as
steps finish. Layers listed as skipped usually have no source data in
`RAW_DIR`; `docker compose run --rm pipeline --status` says why.

If it fails, read the last messages, explain them and offer to rerun
after the fix: `--init` is safe to rerun and never deletes anything.

## 4. Open and next steps

Open the URL it prints (`start http://localhost:8080` in Git Bash) and
check the map loads (run-map skill for screenshots). Then offer next
steps: see what is built (layer-status), add a dataset as a layer
(add-layer), build more layers (build-layers).
