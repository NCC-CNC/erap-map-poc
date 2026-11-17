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
   `coverage`, `points`, `raster`) sets the tippecanoe or GDAL options;
   a layer overrides only zooms and the few settings that need it.
9. **Personal config is simpler.** The git-ignored `map.config.yaml` sets
   the opening view, the basemap and which layers are on. Personal
   layers go in a git-ignored `layers.local/` folder in the same format.
   Per-field overrides of committed layers go.
10. **The GitHub Pages copy works as it does now** (ADR 0014): its own
    build into `data/pages/`, the `web-pages` service, `publish-pages.sh`
    and the release. It needs a way to change a few processing settings
    (lower max zooms, a different protected areas source) without
    editing the layer files; see Open questions.

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

## Pipeline commands

`run.sh [layer ...]` builds layers, then writes `style.json`. Writing the
style alone is quick, so a display change is applied by re-running the
style step (`run.sh --style-only`), with no re-tiling. `--status` and
`--remove` stay, reading `build.json`. Stale detection compares the hash
of the layer file's `source`, `fields` and `processing` sections and the
source file with the hashes in `build.json`.

## Web app

- Loads the basemap style, then `data/tiles/style.json`, and adds its
  sources and layers. No layer is named in `web/`.
- Reads `erap:` metadata for the layer list, legends, themes, pop-ups and
  the modal. TypeScript types for the metadata are generated from the
  layer file schema, so there is one definition.
- Drops `manifest.ts` and its hand-written checks; MapLibre reports a bad
  layer, and a layer whose metadata is missing still draws.

## Docs

- README: what it is, quick start, links (about 150 lines).
- One "how it works" page with a data flow diagram (layer file, pipeline,
  `style.json`, app).
- One layer file reference, generated from or next to the schema.
- Decisions only in ADRs; history out of config comments.
- CLAUDE.md: rules and commands only. Skills updated to the new commands.

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
6. Personal config and `layers.local/`; Pages copy on the new format.
7. Docs, CLAUDE.md and skills.

## Open questions

- How the Pages copy changes processing settings: a second, small file
  of processing overrides per layer, or Pages-only layer files.
- Which JSON Schema validator to pin in the pipeline image.
