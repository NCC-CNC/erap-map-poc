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
   `simplify_px` (and `min_visible_px` and `grey_levels`; see Settled in
   step 1).
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
  keep:                      # a name as it is, or {source: output} to rename
    - ECOREGION_NAME_EN: name
    - protected_pcnt
    - intact_pcnt
    - protected_intact_pcnt
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

Each file has one reader:

| File | For | Contents |
| --- | --- | --- |
| `README.md` | everyone | what it is, quick start, everyday commands, links (about 150 lines) |
| `docs/how-it-works.md` | anyone | data flow diagram (layer file, pipeline, tiles and `style.json`, app) and what each step and output is |
| `docs/guide.md` | people running the map | each task as plain commands: add a layer, change its look, its pop-up or modal, update its data, remove it, personal layers, publish the Pages copy |
| `docs/layer-file.md` | people writing layer files | every key of the layer file and map config, with examples |
| `pipeline/README.md` | developers | what is in `pipeline/` and what each script in `bin/` and `lib/` does |
| `scripts/README.md` | developers | what each script in `scripts/` does and how to run it |
| `web/README.md` | developers | how the app is laid out in `src/` and how it reads `style.json` |
| `CONTRIBUTING.md` | developers | dev setup, checks, pull requests, repo automation (about 120 lines) |
| `CLAUDE.md` | Claude | rules and where the commands are (about 60 lines) |

- Design notes: `00_project_brief.md` stays; `01_architecture.md` is
  replaced by `how-it-works.md`; `02_data_layers_and_popups.md` is split
  (reference into `layer-file.md`, decisions into ADRs, per-layer choices
  from #14 into short comments in the layer files); `03_milestones.md` is
  updated; this note stays until the refactor is done.
- ADRs: new ADRs record the refactor and mark 0007, 0009, 0011 and 0012
  superseded where they are; 0005 and 0008 are marked superseded too.
- Comments in config and code say what and why, briefly; issue-by-issue
  history stays in git and the issues.
- `CHANGELOG.md` and `docs/handoffs/` go; git history and merged PRs are
  the record.
- Every task (add, restyle, build, check, remove a layer; run the map) is
  documented as plain commands first, in `guide.md`.

Skills go from 11 to 9, each a thin wrapper of about 40 lines that links
to its `guide.md` section and runs the same commands: `restyle-layer` and
`edit-popup` merge into `edit-layer`, and `layer-status` folds into
`build-layers`. `add-layer`, `update-layer-data`, `remove-layer`,
`inspect-data`, `run-map`, `run-checks` and `setup` stay. A skill that
needs more than the documented commands is a sign a command is missing.

## Order of work

Each step is an issue and a PR into `dev`, keeping the map working where
practical:

1. Layer file schema and format; convert the four layers and the two test
   layers.
2. Pipeline reads layer files (bash, `yq`, `jq`, validator), including
   calculated fields as SQLite; Node and `pipeline/style/` removed.
3. Pipeline writes `style.json` and `build.json`; `manifest.json` removed.
4. App loads `style.json` and reads metadata; legends from expressions;
   generated types.
5. Joins.
6. Map config (`map.config.yaml`, `map.pages.yaml`) and `layers.local/`;
   Pages copy and `publish-pages.sh` on the new format.
7. Docs (README, guide, layer file reference, READMEs in `pipeline/`,
   `scripts/` and `web/`), ADRs, CLAUDE.md and skills.

## Settled in step 1

- The validator is `jv` from santhosh-tekuri/jsonschema (a static binary
  that reads YAML directly), with mikefarah `yq`; both pinned with
  checksums in the pipeline image.
- The schemas are `pipeline/schema/layer.schema.json` and
  `pipeline/schema/map.schema.json`. The old `map-config.schema.json`
  stays until step 6 switches the map config over.
- `processing` also keeps `min_visible_px` (the drop guard threshold,
  any vector layer; `protected_areas` needs 4) and `grey_levels` (raster
  only; the Pages copy uses 8). `coverage` generalises every zoom below
  `maxzoom`.
- `display.themes`: the first theme is what `display.layers` draw and has
  no `paint`; each other theme sets paint properties per style layer id.
- Every converted layer sets an explicit `legend` for now (labels such
  as "No data" or "30 to 100" are not in the expressions); step 4 drops
  those the app derives the same.

## Settled in step 2

- `lib/layerfile.sh` reads every layer file once per run: `jv` against
  `layer.schema.json` (again after the map config's overrides), then
  checks a schema cannot make (zooms in order, attribute names unique,
  style layer and theme ids, a full legend while the app still needs
  one). A layer with problems is `invalid` in `--status` and fails its
  build before any data is read; the others still build.
- Presets: every vector preset keeps the max zoom at full detail
  (`--simplify-only-low-zooms`, ADR 0013). `default` adds nothing;
  `coverage` adds `--no-simplification-of-shared-nodes
  --drop-smallest-as-needed` and generalises every zoom from `minzoom` to
  `maxzoom - 1`; `points` adds `--drop-rate=1`. `raster` is the GDAL
  path. There is no way to pass other tippecanoe flags (#122).
- `source.id` is read into an internal attribute, `_feature_id`, which
  tippecanoe writes as the feature id and drops from the attributes.
- Calculated fields are one nested query, each field a level, so a field
  can use the ones above it. GDAL types a new attribute from its first
  value; a field whose values are all numbers is written back as numbers
  when that first value is NULL. A failing expression is found field by
  field and named in the error.
- The map config switched to `map.config.yaml` and `map.pages.yaml`
  (`map.schema.json`) here, as the old JSON format's overrides were the
  `.env` and `.style.json` settings that went. `require` checks that the
  source exists. `layers.local/` stays with step 6.
- Staleness is by hash only: `build_sha256` (effective `source`, `fields`,
  `processing`) and `display_sha256` (`title`, `visible`, `order`,
  `display`) in the manifest's provenance, plus the source data's
  modification time. A build from before layer files has no hash and is
  stale.
- Until step 4, the display block keeps the old resolver's shape for the
  app: `defaultVisible`, the first theme's `paint` filled from
  `display.layers`, `defaultTheme` the first theme. The web tests' copy of
  the old display schema is `web/src/test/layer-style.schema.json`.

## Settled in step 3

- `style.json` keeps what MapLibre does not know about in
  `metadata["erap:layers"]`, an object keyed by layer name: `title`,
  `type` (vector or raster), `order`, `visible`, and `legend`, `themes`,
  `popup` and `modal` as the layer file has them (the first theme has no
  `paint`). Each style layer has `metadata["erap:layer"]`; the basemap is
  `metadata["erap:basemap"]`, the view `center` and `zoom`.
- `style.json` is also where a layer's display is kept between runs: a
  build or `--style-only` takes a layer's part from its layer file, every
  other built layer keeps its part as it was (or takes it from its layer
  file if it has none, such as a layer back in the map config). So a
  display change still shows as `restyle` until applied, and a layer file
  with problems does not take its layer off the map.
- `build.json` is the manifest without `display`, `enabled` and `map`:
  `{updated_at, layers: [...]}`, one entry per built layer with the build
  report, `provenance` and `display_updated_at` (set when the display hash
  changes). A leftover `manifest.json` is deleted when `style.json` is
  written.
- `scripts/publish-pages.sh` reads `build.json` and uploads it with
  `style.json` and the archives (until step 6); `scripts/screenshot.sh`
  waits for `style.json`.
- The pipeline no longer writes the old display block, so the web tests'
  fixtures (`pipeline/tests/fixtures/expected_*display.json`,
  `ecoregions_display.json`) are no longer checked against it; step 4
  removes them with the app's manifest reader.
