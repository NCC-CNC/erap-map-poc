---
name: restyle-layer
description: Change how an existing map layer looks or what its pop-up shows (colours, classes, attribute to colour by, legend, title, order, visibility, pop-up stats and charts) by editing only pipeline/layers/<name>.style.json, with before and after screenshots and a draft PR. Use when asked to restyle, recolour or change the legend or pop-up of a layer.
---

# Restyle a layer

Edit only `pipeline/layers/<name>.style.json`. If the change needs a field
that is not in the tiles, it is not a restyle: add the field to
`LAYER_FIELDS` in `<name>.env` and say so in the PR. Reference:
`docs/design/02_data_layers_and_popups.md` (Display config) and
`pipeline/schema/layer-style.schema.json`. Never commit data or
screenshots.

## 1. Before

Make sure the layer is built (`data/tiles/<name>.pmtiles` and its entry in
`data/tiles/manifest.json`); if not, run step 3 first. Pick two or three
views from the entry's `bounds` (`zoom/lat/lon`) and take the before
shots:

```sh
scripts/screenshot.sh -n <name>-before <z/lat/lon> <z/lat/lon> ...
```

## 2. Edit

Make the change in `<name>.style.json`. Attribute names are the output
names from `LAYER_FIELDS`; for values and ranges, read the layer entry in
the manifest or run
`docker compose run --rm --build --entrypoint inspect.sh pipeline <LAYER_INPUT>`.

## 3. Rebuild

```sh
docker compose run --rm --build pipeline <name>
```

The display config is checked before tiling; a problem fails the layer
with one line per issue and keeps the previous build. Fix and rerun.

## 4. After

```sh
scripts/screenshot.sh -n <name>-after <same views>
```

Compare before and after on both basemaps (files in `tmp/screenshots/`),
check the legend and any `page error` lines, iterate, and show the user
the final pair.

## 5. Draft PR

Branch from `main` (`feat/style-<name>`), commit only the
style file (for example `feat(layers): colour <name> by habitat`), push,
and open a DRAFT PR describing the change and that before and after
screenshots were checked. Never mark it ready: ready PRs merge themselves.
