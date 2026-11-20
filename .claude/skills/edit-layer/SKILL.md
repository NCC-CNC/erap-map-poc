---
name: edit-layer
description: Change how an existing map layer looks or what a click on it shows, by editing its layer file - colours, class breaks, attribute to colour by, "Colour by" themes, legend, title, order, visibility, raster colour and opacity, or its pop-up (small pop-up or dialog; title, sections, attributes, tables, bar, line, pie and doughnut charts, text, lists, number formats) - applied with `pipeline --style-only` (no re-tiling) unless a new attribute must be tiled, with before and after screenshots and a draft PR. Use when asked to restyle or recolour a layer, add or change its colour themes or legend, or add, remove or change what its pop-up or dialog shows.
---

# Edit a layer's look or pop-up

Guide: `docs/guide.md`, Change how a layer looks and Change a pop-up;
keys in `docs/layer-file.md` (display). From the repo root in Git Bash.

1. Ask whether the change is for everyone (the committed layer file and
   a draft PR) or the user only. For the user only, copy the layer file
   to `pipeline/layers.local/` under a new name, edit and build that,
   and leave the committed one out of `layers` in their
   `map.config.yaml` (a map config cannot override a display, and a
   local file cannot repeat a committed name).
2. Read the layer file. Screenshot the layer before (run-map skill), with
   `-c` for a pop-up and `--tab` for a dialog tab, at its `center` in
   `data/tiles/build.json`.
3. Edit only `display` (and `title`, `visible`, `order`):
   - colours and classes in `display.layers` (MapLibre expressions,
     breaks written in the file; `inspect.sh` shows a field's range);
   - themes in `display.themes` (the first has no `paint`), and a
     `legend` only where the derived one is not enough;
   - the pop-up in `display.popup`: `size: small` (one section) or
     `dialog` (a heading per section), blocks, and formats `number`,
     `integer`, `percent` or `{preset, decimals, suffix}`.
4. Is every attribute used in the tiles? Check `fields.keep` and
   `fields.calculated`. If not, add it there (a calculated value is a
   SQLite expression, never done in the app) and rebuild:
   `docker compose run --rm pipeline <name>`. Otherwise apply in seconds:

   ```sh
   docker compose run --rm pipeline --style-only <name>
   ```

   `--status <name>` lists any problem in the file.
5. Screenshot after, compare with the user, and repeat until happy.
6. For everyone: a branch, a `feat:` commit with the layer file only, and
   a draft PR with the before and after described (screenshots never go
   in git).
