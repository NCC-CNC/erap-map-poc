---
name: restyle-layer
description: Change how an existing map layer looks (colours, classes, gradients, attribute to colour by, switchable colour themes for "Colour by", legend, title, order, visibility; for raster layers colour and opacity) by editing only pipeline/layers/<name>.style.json and applying it with `pipeline --style-only` (no re-tiling), with before and after screenshots and a draft PR. Use when asked to restyle or recolour a layer, add or change its colour themes, or change its legend. What a pop-up or modal shows is the edit-popup skill.
---

# Restyle a layer

Edit only `pipeline/layers/<name>.style.json`. If the change needs a field
that is not in the tiles, it is not a restyle: add the field to
`LAYER_FIELDS` in `<name>.env`, do a full build in step 3, and say so in
the PR. Reference: `docs/design/02_data_layers_and_popups.md` (Display
config; Colour themes and gradients) and
`pipeline/schema/layer-style.schema.json`. Never commit data or
screenshots. To change what a pop-up or modal shows (stats, sections,
tables, charts, formats), use the edit-popup skill instead.

Several colours to switch between (for example protected, Where To Work
and intact for one layer) are colour `themes` in the shorthand, each with
an `id`, `label` and colour rule, plus a `defaultTheme`; the map shows a
"Colour by" list for them. A continuous ramp is an `interpolated` rule
(`stops`, or `colors` with `min` and `max`, each from the data when left
out) with a gradient legend. To screenshot another theme:
`scripts/screenshot.sh --colour-by <name>=<theme id> ...`.

First ask, unless the user already said: is this change just for them,
or for everyone? Just for them: put it in their git-ignored
`map.config.json` (README, Your map config; ADR 0009) as
`overrides.<name>` with `title`, `order`, `defaultVisible` or a `style`
patch (merged over the `.style.json`; `null` removes a key, lists are
replaced), run `docker compose run --rm pipeline --style-only <name>`,
take the screenshots as below, and stop: no branch, no PR. For everyone:
the steps below.

## 1. Before

Make sure the layer is built (`data/tiles/<name>.pmtiles`, or
`<name>.cog.tif` for a raster layer, and its entry in
`data/tiles/manifest.json`); if not, build it first
(`docker compose run --rm --build pipeline <name>`). Pick two or three
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
A raster layer (`LAYER_TYPE=raster`) keeps the raster shorthand: only
`color` (`#rrggbb`), `opacity`, `label`, title, order and visibility. Its
COG holds the share of each pixel covered, not a colour, so any colour or
opacity change is `--style-only`, never a rebuild. One colour per raster
layer: a ramp or classes are not supported (binary rasters only).

## 3. Apply

A display-only change (the usual case, vector or raster):

```sh
docker compose run --rm pipeline --style-only <name>
```

It checks the config as a build does, updates the layer's manifest entry
and `style.json`, and leaves the tiles or COG alone (seconds, even for a
Canada-wide layer). A bad config fails with one line per problem and
changes nothing: fix and rerun. If it says the pipeline does not know
`--style-only`, the image is old: add `--build` once.

Do a full build (`docker compose run --rm --build pipeline <name>`)
instead only when `<name>.env` changed too (a new field in `LAYER_FIELDS`,
zooms), or when `--style-only` says the `breaks` data changed since the
build. Afterwards `docker compose run --rm pipeline --status <name>` should
say `current`.

## 4. After

```sh
scripts/screenshot.sh -n <name>-after <same views>
```

Compare before and after on both basemaps (files in `tmp/screenshots/`),
check the legend and any `page error` lines, iterate (edit, `--style-only`,
screenshot), and show the user the final pair.

## 5. Draft PR

Branch from `main` (`feat/style-<name>`), commit only the
style file (plus the `.env` if step 3 needed a build; for example
`feat(layers): colour <name> by habitat`), push, and open a DRAFT PR
describing the change and that before and after screenshots were checked.
Never mark it ready: ready PRs merge themselves.
