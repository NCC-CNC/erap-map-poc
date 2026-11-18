---
name: update-layer-data
description: Refresh an existing map layer (vector, or a binary raster) after its source dataset in RAW_DIR was replaced or updated - re-inspect the new data, compare fields, CRS, geometry and feature count (a raster - bands, values, nodata, extent) with what the layer file expects, flag breaking changes, rebuild, and compare before and after screenshots. Use when asked to update, refresh or reload a layer's data, or when a new version of a dataset arrives.
---

# Update a layer's data

Guide: `docs/guide.md`, Update a layer's data. From the repo root in Git
Bash.

1. Read the layer file (`pipeline/layers/<name>.yaml`, or
   `pipeline/layers.local/`): `source` (path, layer, id, joins),
   `fields.keep` and `fields.calculated`. Note the old feature count and
   size from `docker compose run --rm pipeline --status <name>`.
2. Screenshot the layer as it is now (run-map skill), at its `center`
   in `data/tiles/build.json`.
3. Inspect the new data (inspect-data skill) and compare: every source
   field in `fields.keep` and every join key still there, the id still a
   unique integer, the same CRS and geometry type, the feature count (a
   big change is worth asking about); for a raster, still single-band
   binary with the same nodata. A new file name means a new
   `source.path`.
4. Breaking changes: tell the user and agree the edit to the layer file
   (a renamed field becomes `{NEW_NAME: old_output_name}` in
   `fields.keep`, so the display and pop-up keep working).
5. Rebuild (say how long first) and explain any failure as in the
   build-layers skill; a failed build keeps the old tiles:

   ```sh
   docker compose run --rm pipeline <name>
   ```

6. Screenshot again and compare with step 2. If the layer file changed
   and the layer is committed: a branch, a `fix:` or `feat:` commit with
   the layer file only, and a draft PR. A data refresh alone needs no PR.
