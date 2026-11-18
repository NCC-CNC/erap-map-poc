---
name: remove-layer
description: Remove a map layer - delete its layer file (pipeline/layers/<name>.yaml or pipeline/layers.local/<name>.yaml), its built archive (.pmtiles or .cog.tif) and its build.json entry, rewrite style.json, and open a draft PR for a committed layer. Always confirms with the user first. Use when asked to remove, delete, drop or retire a layer, or to clean up an orphaned build.
---

# Remove a layer

Guide: `docs/guide.md`, Remove a layer. From the repo root in Git Bash.

1. Look: `docker compose run --rm pipeline --status <name>` and
   `ls pipeline/layers/<name>.yaml pipeline/layers.local/<name>.yaml`.
   An `orphan` is a build whose layer file is already gone.
2. **Confirm with the user, always**, saying exactly what goes: the
   layer file (committed or local), `data/tiles/<name>.pmtiles` or
   `.cog.tif`, its `build.json` entry and its part of `style.json`. The
   source data and `data/work/raster/` stay (offer to delete the latter
   to reclaim space). For a committed layer, ask whether it goes for
   everyone (a PR) or only from this user's map: then leave it out of
   `layers` in their `map.config.yaml`, run `docker compose run --rm
   pipeline --style-only`, and stop.
3. Remove:

   ```sh
   git rm pipeline/layers/<name>.yaml          # or rm pipeline/layers.local/<name>.yaml
   docker compose run --rm pipeline --remove <name>
   ```

4. For a committed layer: a branch, a `feat: remove <name> layer` commit
   with the layer file only (check `git status`: no data), and a draft
   PR. Remove the layer from any `map.pages.yaml` override or `require`
   in the same PR.
5. Confirm with `--status` that it is gone.
