---
name: add-layer
description: Add a new map layer from a source dataset in RAW_DIR (shapefile, zipped shapefile, GeoPackage, GeoJSON, FileGDB, ..., or a binary GeoTIFF as a display-only raster layer). Inspects the data, writes pipeline/layers/<name>.yaml from inspect.sh --starter (or pipeline/layers.local/ for the user only), builds it, checks the build report and screenshots, and opens a draft PR with the layer file only. Use when asked to add, load or publish a dataset as a layer.
---

# Add a layer

Guide: `docs/guide.md`, Add a layer; every key in `docs/layer-file.md`.
From the repo root in Git Bash.

1. Ask whether the layer is for everyone (`pipeline/layers/`, a draft
   PR) or the user only (`pipeline/layers.local/`, no PR). Pick a name:
   lower case letters, digits, `_` and `-`, not already a layer.
2. Inspect the data (inspect-data skill). Stop and explain if it cannot
   be a layer: no unique integer id for vector data, or a raster that is
   not single-band binary.
3. Write the layer file. Vector:

   ```sh
   docker compose run --rm -T --entrypoint inspect.sh pipeline --starter [--layer NAME] <path> \
     > pipeline/layers/<name>.yaml
   ```

   Raster: copy `pipeline/layers/forest.yaml`, change `source.path`,
   `title`, `order` and the colour. Then edit with the user: the id,
   only the fields they need, `title`, `visible`, `order`, colours (class
   breaks from the field ranges inspect printed) and the pop-up (or none).
   Keep the starter's comments that still apply, and remove its warnings
   once dealt with.
4. Check, then build (say how long first; a raster takes about 10
   minutes, run it in the background):

   ```sh
   docker compose run --rm pipeline --status <name>   # problems in the file
   docker compose run --rm pipeline <name>
   ```

   Explain a failure as in the build-layers skill.
5. Look: screenshot the layer at its `center` from `data/tiles/build.json`
   and, with a pop-up, once with `-c` (run-map skill). Show the user and
   adjust `display` with `--style-only` until they are happy.
6. For everyone: a branch, a `feat: add <name> layer` commit with the
   layer file only (`git status`: never data, archives or screenshots),
   and a draft PR describing the source, its size and the build time.
