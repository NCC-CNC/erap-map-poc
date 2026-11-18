---
name: build-layers
description: Build or rebuild map layers with the pipeline (one, several or all, vector or raster), report which layers are configured, built, stale, invalid or missing their source (with build time, archive size, zooms, feature count and largest tile), and explain any failure from the log and data/tiles/build.json, such as a drop guard failure, and what to change. Use when asked to build, rebuild or refresh layers or tiles, what layers there are, what is built or out of date, or why a layer build failed.
---

# Build layers and check their status

Guide: `docs/guide.md`, Build layers and check their status. From the
repo root in Git Bash.

1. Status, read only:

   ```sh
   docker compose run --rm pipeline --status [layer ...]   # --json for every detail
   ```

   Summarise per layer: `current`, `stale` (source, fields, processing
   or the data changed: rebuild), `not built`, `source missing` (not
   in `RAW_DIR`),
   `invalid` (quote the problems in the layer file), `disabled` (left
   out by `map.config.yaml`) or `orphan` (layer file gone: remove-layer
   skill). If the user only asked what there is, stop here.
2. Build what is needed. Say first how long it may take: seconds to
   minutes per vector layer, about 10 minutes per Canada-wide raster the
   first time (less once `data/work/raster/` has its source); run long
   builds in the background.

   ```sh
   docker compose run --rm --build pipeline <layer> ...   # or no names: every layer
   docker compose run --rm pipeline --style-only   # rewrite style.json only
   ```

3. Report from the log and `data/tiles/build.json`: features, zooms,
   size, drops. On a failure the previous files are kept; explain the
   message and the fix:
   - drop guard (a visible polygon lost at a zoom): raise
     `processing.min_visible_px`, lower `min_part_px`, or add options in
     `processing.tippecanoe`;
   - a field or table not found: the data changed (update-layer-data
     skill);
   - a calculated field: `docker compose run --rm --entrypoint
     inspect.sh pipeline --config <layer>` names the failing expression;
   - source missing for a named layer: check `RAW_DIR` in `.env`.

   Keys are in `docs/layer-file.md`. Then offer to open the map (run-map
   skill).
