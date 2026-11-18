---
name: setup
description: Set up the ERAP map on a new Windows machine, or check one that is not working - runs scripts/setup.sh to check Git Bash, Docker Desktop (running, Linux containers, WSL 2, memory, CPUs, disk), .env, RAW_DIR and the ports, explains each failure with Windows steps, helps write .env, builds the images and layers, starts the map and opens it. Use when asked to set up, install or get started with the map, after cloning the repo, or why Docker or the setup is not working.
---

# Set up the map

Guide: `docs/guide.md`, Set up. All logic is in `scripts/setup.sh`
(`--help` lists the options); this skill runs it and explains the output.
Run from the repo root in Git Bash, never PowerShell or WSL. Not cloned
yet: `git clone https://github.com/NCC-CNC/erap-map-poc.git && cd erap-map-poc`.

1. Check, read only: `scripts/setup.sh --check`. Each line is `ok`,
   `warn`, `FAIL` or `skip` with a `fix:` line. Explain each `FAIL` and
   `warn` in plain words from that fix. Common on Windows: wrong shell
   (open Git Bash); Docker Desktop missing (it comes from IT, never try
   to install it); engine not running (start Docker Desktop; access
   denied means IT adds the account to `docker-users`); old WSL (`wsl
   --update` in PowerShell); low memory or CPUs (only rasters need more;
   `%USERPROFILE%\.wslconfig`); a port in use. Fix every `FAIL` first;
   ask before changing anything outside the repo.
2. Ask where the source data lives (a folder outside the repo, such as
   `C:/data/ERAP_play_data`), or none yet. Ask about ports only if one
   is busy.
3. Init, in the background, reporting as steps finish:

   ```sh
   scripts/setup.sh --init --yes --raw-dir 'C:/path/to/data' [--web-port N] [--skip-layers]
   ```

   Say first that it takes about 5 minutes plus the layers (about 10
   minutes per raster the first time); offer `--skip-layers`. An
   existing `.env` is kept unless a flag changes it (with a backup).
   Skipped layers usually have no data in `RAW_DIR`; `docker compose run
   --rm pipeline --status` says why. On failure, explain the last
   messages; `--init` is safe to rerun.
4. Open the printed URL (`start http://localhost:8080`) and check the map
   loads (run-map skill). Offer next steps: build-layers, add-layer.
