---
name: layer-status
description: Report which map layers are configured and which are built, which builds are stale (a config or the source data changed since the build), and each layer's build time, archive size, zooms, feature count and largest tile. Use when asked what layers there are, what is built, what is out of date or needs rebuilding, or for an overview of the tiles.
---

# Layer status

Read only. Run from the repo root in Git Bash:

```sh
docker compose run --rm --build pipeline --status            # every layer
docker compose run --rm --build pipeline --status <name> ...  # some layers
docker compose run --rm --build pipeline --status --json     # for detail
```

Each layer has one state, with notes under it saying why:

- `current`: built after its `.env`, `.style.json` and source data last
  changed.
- `stale`: a config or the source data changed since the build (by file
  time), or the archive is missing. Rebuild it (build-layers skill).
- `not built`: configured, never built (or every build failed).
- `invalid`: cannot build as configured: the `.env` does not load, the
  `.style.json` is missing, or the source data is not in `data/raw/`. Any
  previous build is still served.
- `orphan`: built, but its `.env` is gone. Offer the remove-layer skill.

Staleness goes by file times only: a pipeline code change, or a source
file replaced by an older copy, does not show. When in doubt, rebuild.

## Report

Give a short table (layer, state, built, size, zooms, features, largest
tile) and then what to do: which layers to rebuild, which configs to fix
and how (from the notes), and any orphan to remove. Flag a largest tile
over about 500 kB. For a layer's full build report (per zoom: features
present and required by the drop guard, tile sizes), read its entry in
`data/tiles/manifest.json`.
