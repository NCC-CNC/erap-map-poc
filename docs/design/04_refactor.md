# 04 Refactor

Direction for the refactor on the `dev` branch. Each change lands as a
PR into `dev`; `dev` merges into `main` when the map works end to end
again. ADRs that this replaces (0007, 0009, 0011) are marked superseded
as the work lands.

## Why

The PoC works, but it is hard to follow. One layer is spread over up to
five files (`<layer>.env`, `.style.json`, `.rules.json`, `map.config.json`,
`.env` at the root). The same display rules exist three times: a 729-line
JSON Schema, the Node resolver in `pipeline/style/` and hand-written checks
in `web/src/layers/manifest.ts`. The pipeline switches between bash and
Node, and the app reads a custom `manifest.json` rather than a standard
format.

## Goal

Adding a layer, or a different kind of source, means adding one file.
Nothing about a layer is hard-coded in the pipeline or the app.

A person can configure and run everything with only the repo and Docker:
edit a layer file, run a documented `docker compose` command, open the
map. Claude Code skills are an alternative way to do the same thing, never
the only way: each skill runs those same documented commands with the
right arguments and holds no logic of its own. Anything a skill needs that
the commands cannot do yet is added to the pipeline or `scripts/` first,
with tests, and documented for people.

## Decisions

1. **One file per layer**, `pipeline/layers/<layer>.yaml`, with four
   sections: `source`, `processing`, `fields` and `display`. It replaces
   `<layer>.env`, `<layer>.style.json` and `<table>.rules.json`.
2. **The output is a standard MapLibre style.** The pipeline writes
   `data/tiles/style.json` (sources, layers in draw order) and the app
   loads it over the basemap. Anything MapLibre does not know about
   (title, legend, pop-up, modal, colour themes, visible by default) goes
   in the style's `metadata`, which the spec reserves for app data, under
   `erap:` keys. `manifest.json` goes away. No other app opens these files.
3. **`display` is plain MapLibre.** A layer's `display.layers` are MapLibre
   style layers (`paint`, `layout`, expressions such as `step` and
   `match`), written as they will appear in `style.json`. The pipeline adds
   the `source`, `source-layer` and a prefixed `id`; it does not translate
   a symbology language. Colour themes are alternative `paint` blocks in
   metadata. Class breaks are written in the file (no computed quantiles).
4. **The app reads legends from the expressions.** For `step`, `match`
   and `interpolate` colours the app builds the legend itself; a layer
   can set `erap:legend` where that is not enough.
5. **The pipeline stays bash, without Node.** Bash runs the GDAL,
   tippecanoe and `pmtiles` commands; `yq` and `jq` read the layer files
   and write JSON; a pinned JSON Schema validator checks each layer file
   against one schema. The style itself is checked against the MapLibre
   style spec in the web app's tests, not in the pipeline image.
6. **Sources are anything GDAL opens, plus non-spatial joins.** `source`
   names a path under `RAW_DIR` (and a layer in it, for a geodatabase or
   GeoPackage). `source.joins` adds attributes from a CSV or table by a
   key, run with GDAL. Remote files and databases are out of scope for
   now; the format leaves room for them.
7. **Calculated fields are SQLite expressions.** `fields.calculated` maps a
   new attribute to an expression, run by `ogr2ogr -dialect SQLite`. The
   files are committed and trusted, so there is no custom parser. Action
   recommendations become calculated fields too (one true or false
   attribute per action), with their titles and reasons in the modal
   config. There is no separate rules file.
8. **Processing uses presets.** `processing.profile` (`default`,
   `coverage`, `points`, `raster`) sets the tippecanoe or GDAL options.
   Low-zoom generalisation and the drop guard live inside `coverage`; a
   layer overrides only `minzoom`, `maxzoom`, `min_part_px` and
   `simplify_px`.
9. **One map config format, two files.** Your git-ignored, optional
   `map.config.yaml` and the committed `map.pages.yaml` share one schema
   with five keys: `view`, `basemap`, `layers` (which layers to build;
   default all), `overrides` (per layer, `source` and `processing` only)
   and `require` (fail if a layer's source is missing). Display and field
   overrides go, and so does provenance tracking. See Map config.
10. **Personal layers** go in the fixed, git-ignored `layers.local/`
    folder, in the same format, built like committed layers. A name that
    repeats a committed layer is an error.
11. **The GitHub Pages copy works as it does now** (ADR 0014): its own
    build into `data/pages/` from `map.pages.yaml`, the `web-pages`
    service, `publish-pages.sh` and the release. Its display is the same
    as the main map.

## A layer file

Shortened from today's `ecoregions`:

```yaml
title: ERAP ecoregions
visible: true
order: 40

source:
  path: ERAP_2026_ecoregions.gdb
  layer: ERAP_2026_ecoregions
  id: OBJECTID
  # joins:
  #   - path: ecoregion_stats.csv
  #     on: ECOREGION_ID

fields:
  keep:
    ECOREGION_NAME_EN: name
    protected_pcnt: protected_pcnt
    intact_pcnt: intact_pcnt
    protected_intact_pcnt: protected_intact_pcnt
  calculated:
    unprotected_intact_pcnt: round(intact_pcnt - protected_intact_pcnt, 2)
    action_area_based_30x30: protected_pcnt < 30

processing:
  profile: coverage
  maxzoom: 12

display:
  layers:
    - id: fill
      type: fill
      paint:
        fill-color:
          [step, [get, protected_pcnt], "#deebf7",
           10, "#9ecae1", 17, "#4292c6", 30, "#08519c"]
        fill-opacity: 0.7
  themes: []   # alternative paint blocks for "Colour by"
  popup: {}    # as today: title, stats, charts
  modal: {}    # as today: tabs, sections, tables, charts
```

The pop-up and modal keep today's structure; they move into the file
as they are, apart from renaming where that makes them clearer.

## Outputs

| File | Read by | What |
| --- | --- | --- |
| `data/tiles/<layer>.pmtiles` | app | vector tiles |
| `data/tiles/<layer>.cog.tif` | app | raster COG |
| `data/tiles/style.json` | app | MapLibre style of the data layers, `erap:` metadata |
| `data/tiles/build.json` | `--status` only | per-layer build report (counts, sizes, drops, source hash) |

## Pipeline

What stays, in bash as now: reading sources with `ogr2ogr`
(`normalise.sh`), low-zoom generalisation, tippecanoe and `pmtiles`, the
drop guard, the raster steps with their cache in `data/work/`, and
`inspect.sh`, which also prints a starter layer file for a dataset.

What goes: `pipeline/style/` (Node, its packages and tests),
`lib/display.sh`, `lib/derive.sh`, `lib/mapconfig.sh`, most of
`lib/manifest.sh`, the three schemas (replaced by `layer.schema.json` and a
small `map-config.schema.json`) and class breaks computed from the data
(written in the file instead; `inspect.sh` can suggest them). The image
loses Node and gains `yq` and a schema validator.

A build: read and check the layer file, read the source (with joins and
calculated fields), tile or warp, record the build in `build.json`, then
write `style.json` from every built layer's `display`.

Commands stay: `run.sh [layer ...]`, `--style-only` (rewrites
`style.json` only, no re-tiling), `--status` and `--remove`, reading
`build.json`. Stale detection compares the hash of the layer file's
`source`, `fields` and `processing` sections and the source file with the
hashes in `build.json`; a change to `display` alone is `restyle`.

Tests: bats covers every pipeline step and command, kept and adapted where
the code stays, new for layer file reading and checking, joins, calculated
fields, `style.json` assembly, `build.json`, `--status` and the map
config (overrides, `require`, `layers.local/`).
Tests of deleted code go with it.

## Map config

```yaml
# map.config.yaml: yours, git-ignored, optional
view: { center: [-96, 60], zoom: 3 }
basemap: light
layers: [ecoregions, protected_areas, forest]   # omit for every layer
```

```yaml
# map.pages.yaml: committed, read by pipeline-pages
view: { center: [-96, 60], zoom: 3 }
basemap: light
overrides:
  forest: { processing: { maxzoom: 10 } }
  agriculture: { processing: { maxzoom: 10 } }
  ecoregions: { processing: { maxzoom: 10 } }
  protected_areas:
    source:
      path: ProtectedConservedArea_2025.gdb
      layer: ProtectedConservedArea_2025
    processing: { maxzoom: 10 }
require: [protected_areas]
```

- The pipeline writes `view` and `basemap` into `style.json` (`center`,
  `zoom`, `metadata["erap:basemap"]`); the app needs nothing else.
- Compose keeps its services: `pipeline` reads `map.config.yaml` when it
  exists (`MAP_CONFIG` in `.env` picks another file); `pipeline-pages`
  reads `map.pages.yaml` and writes `data/pages/`; `web-pages` is
  unchanged.
- `publish-pages.sh` keeps its steps (check, dry run, upload to the
  `pages-data` release, run the workflow) and reads its file list from
  `build.json` and `style.json`.
- Anyone with a `map.config.json` rewrites it by hand; the README says
  how. There is no migration script.

## Web app

What stays: React and MapLibre, the basemap toggle, the layer panel (on
and off, "Colour by"), legends, pop-ups, the modal, charts and number
formats, all looking and working as now. The basemap loads first and the
data layers go on top; a basemap switch adds them again with their
visibility and theme. The view stays in the URL hash.

How it reads `style.json`:

- A short loader checks it is a version 8 style. Each style layer carries
  `metadata["erap:layer"]` (the map layer it belongs to, such as
  `ecoregions`); the style's top-level `metadata["erap:layers"]` holds each
  map layer's title, order, visibility, themes, legend, pop-up and modal.
- Sources are written by the pipeline as relative `pmtiles://` and `cog://`
  URLs; the app resolves them against the tiles URL, so the same file
  works locally and on Pages.
- The opening view is the style's own `center` and `zoom`, the basemap
  `metadata["erap:basemap"]`.
- Legends come from the colour expression (`step`, `match`,
  `interpolate` or a single colour, per theme), unless the layer sets
  `erap:legend`. They should match today's; where one does not, the layer
  gets an explicit legend.
- TypeScript types for the metadata are generated from
  `layer.schema.json`.
- A bad layer shows up through MapLibre's error events: the panel names
  it and the other layers still draw.

What goes: `manifest.ts` and its hand-written checks, `types.ts`,
`schema.test.ts`, the check that each archive exists (the pipeline only
writes built layers) and the raster PNG path (rasters are COG only, ADR
0010).

Tests: vitest covers the loader (valid, missing, bad), legends from each
expression type, themes, and pop-up and modal content. CI checks the test
layers' `style.json` with the MapLibre style validator.

## Docs

- README: what it is, quick start, links (about 150 lines).
- One "how it works" page with a data flow diagram (layer file, pipeline,
  `style.json`, app).
- One layer file reference, generated from or next to the schema.
- Decisions only in ADRs; history out of config comments.
- CLAUDE.md: rules and commands only.
- Every task (add, restyle, build, check, remove a layer; run the map) is
  documented as plain commands first. Each skill links to that section and
  runs the same commands; a skill that needs more than that is a sign the
  command is missing.

## Order of work

Each step is an issue and a PR into `dev`, keeping the map working where
practical:

1. Layer file schema and format; convert the four layers and the two test
   layers.
2. Pipeline reads layer files (bash, `yq`, `jq`, validator); Node and
   `pipeline/style/` removed.
3. Pipeline writes `style.json` and `build.json`; `manifest.json` removed.
4. App loads `style.json` and reads metadata; legends from expressions;
   generated types.
5. Calculated fields as SQLite and joins.
6. Map config (`map.config.yaml`, `map.pages.yaml`) and `layers.local/`;
   Pages copy and `publish-pages.sh` on the new format.
7. Docs, CLAUDE.md and skills.

## Open questions

- Which JSON Schema validator to pin in the pipeline image.
