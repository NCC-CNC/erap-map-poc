# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The first real vector layers, from the November 2026 play data (#58):
  `ecoregions` (`ERAP_2026_ecoregions.gdb`, 149 ecoregions, on top,
  clickable) with four blue colour themes (% protected by default, Where
  To Work % and total area, area-based conservation actions), the click
  modal of #14 (Summary, Habitat, Direct threats, Opportunities, Action
  recommendations), the calculated fields and the action rules, and
  low-zoom generalisation to z7; and `protected_areas`
  (`protected_areas.gdb`, the dissolved CPCAD, 112,050 polygons, one
  green fill, no pop-up). The ecoregion template moved from
  `pipeline/tests/fixtures/ecoregions.example.*` to
  `pipeline/layers/ecoregions.*`, and the display config and web tests
  read the committed file (`web-dev` mounts `pipeline/layers/`
  read-only). Design note 02 records both layers, the decisions from #14
  and what is still open (licences, provenance, update frequency and
  stable ids, #13). `forest` is now off by default; order bottom to top:
  forest, agriculture, protected areas, ecoregions.
- Calculated fields and action recommendation rules (#60, ADR 0011): all
  calculations happen in the pipeline, the app only displays tile
  attributes. `LAYER_CALCULATED` in a layer's `.env` adds attributes from
  `name=expression` entries, and `LAYER_RULES` names a committed rules
  table, `pipeline/layers/<table>.rules.json` (schema
  `pipeline/schema/action-rules.schema.json`), whose actions become
  `action_<id>`, `action_<id>_reason` and `actions_<type>_count`
  attributes. Expressions are a small SQL-like language parsed by the
  display config tool (`style/derive.mjs`) and evaluated with GDAL's
  SQLite dialect (`lib/derive.sh`): no statements, subqueries, comments or
  functions outside an allow-list, every name quoted, problems reported
  per field or rule before the source data is read. The first table,
  `ecoregions.rules.json`, holds the one known rule (30x30, when
  `protected_pcnt < 30`). The build report gains `calculated_fields` and
  `rules` (counts per action and type) and the provenance
  `rules_sha256`; `--status` lists them and calls a build stale when the
  rules table changes; `inspect.sh --config <layer>` shows a layer's data
  as built, calculated fields and rule counts included; `cli.mjs check`
  checks `.rules.json` files; the map config's overrides gain
  `calculated` and `rules`. Low-zoom generalisation and `--style-only`
  breaks keep the derived attributes.
- Click modal, colour themes, gradients and number formats (#57, ADR
  0012). A layer's `.style.json` may have a `modal` instead of a `popup`:
  one template (title and subtitle with `{attribute}`,
  `{attribute:preset}` and `{$id}` placeholders, then sections of
  attribute lists, tables, bar, grouped bar, pie and doughnut charts, text
  and lists with a message for none), filled from the clicked feature's
  tile attributes; whatever a feature lacks is hidden. The app shows it
  in an accessible dialog (focus trap, Escape and close button, focus
  returned, scrolls, full screen on narrow screens, closes when the layer
  is hidden). The polygon and point shorthand may give colour `themes`
  (with a `defaultTheme`) instead of one `color`: the layer panel offers
  "Colour by", which switches the paint and legend in the browser with no
  rebuild. New `interpolated` colour rule (a gradient from `stops`, or
  `colors` over `min` to `max`, from the data when left out) with a
  `gradient` legend. Formats may be a preset (`number`, `count`,
  `percent`, `hectares`, `km`) or an object with a `preset`; `%` now
  follows a number with no space. The display config tool checks table
  and chart lengths and placeholders; `--style-only` re-reads the data for
  a gradient range from the data, in any theme. Chart.js now loads on
  first use. `scripts/screenshot.sh` gains `--click` (click the view's
  centre, to capture a pop-up or modal) and `--colour-by LAYER=THEME`,
  tested in `scripts/tests/screenshot.bats`. New `edit-popup` skill for
  pop-up and modal content; `restyle-layer` keeps colours, themes and
  legends. The ecoregion template, from the play data's attributes, is an
  example in `pipeline/tests/fixtures/ecoregions.example.*` until #58.
  Tests: `style/test/themes_modal.test.mjs`, `display.bats`,
  `style_only.bats`, and web tests for the template, themes, chart
  configs, the schema agreement and the dialog and layer panel in jsdom
  (a new pinned dev dependency).
- Local map config (#59, ADR 0009): a git-ignored `map.config.json` at
  the repo root (`MAP_CONFIG` in `.env` picks another file;
  `map.config.example.json` is committed), with a JSON Schema
  (`pipeline/schema/map-config.schema.json`) checked by the display config
  tool (`cli.mjs layers`, `style/mapconfig.mjs`, `lib/mapconfig.sh`). It
  selects layers (`enabled`, `disabled`), overrides them (`input` and
  `env` change the tiles; `title`, `order`, `defaultVisible` and a `style`
  merge patch change only the display), adds local-only layers
  (`localLayers` inline, or `layerDirs` such as the git-ignored
  `pipeline/layers.local/`) and sets the map's opening view and basemap
  (`map`). The whole config is checked before anything is built (exit 2
  and one line per problem). No file means the previous behaviour.
  Compose mounts the repo read-only at `/repo` in the pipeline container
  for it. A full build now skips layers whose source data is missing
  (warning and summary; exit 1 only if nothing could be built), while a
  named layer still fails; `--status` gains the states `source missing`
  and `disabled`, and compares hashes of the effective settings and
  display config so map config changes show as `stale` or `restyle`.
  Manifest entries gain `enabled` (a layer left out by the config is kept
  but hidden) and `provenance` (origin, source path, size and time, the
  overrides applied, the hashes); the manifest gains `map`, which
  `style.json` also takes. The web app hides disabled entries, opens at
  the config's view (unless the URL has one) and on its basemap. Tests:
  `mapconfig.bats`, `style/test/mapconfig.test.mjs`, web
  `mapconfig.test.ts` and `view.test.ts`. The skills offer "just for me"
  (the map config) next to "for everyone" (the committed files and a PR).
  `scripts/setup.sh` skips `source missing` layers like `invalid` ones,
  reports `disabled` ones, and knows `MAP_CONFIG` as a `.env` setting.
- `pipeline --style-only [layer ...]` (#53): apply `<layer>.style.json`
  changes to built layers, vector or raster, without re-tiling. Each
  config is checked as in a build, the `display` block of the layer's
  `manifest.json` entry is replaced (atomically; `built_at` and the build
  report are kept) and `style.json` is rewritten. No names means every
  built layer with a display config. A layer with no archive is a usage
  error (exit 2); a bad config fails that layer and leaves its entry
  unchanged (exit 1). A stepped colour with `breaks` re-reads the source
  data (no tiling), and fails if the source or `.env` changed since the
  build. Manifest entries gain `display_updated_at` (a build sets it to
  `built_at`). `--status` now compares `.style.json` with it: a layer
  whose only change is its display config shows as the new state
  `restyle`, while a changed `.env` or source still shows `stale` after a
  style-only update. The CI web smoke test runs the new
  `scripts/check-tiles-cache.sh`, which checks that nginx serves
  `manifest.json` and `style.json` with `no-cache` and an ETag (304 while
  unchanged, the new file once changed), so a reload is enough. The
  `restyle-layer` skill uses `--style-only` (a full build only when the
  `.env` must change), `build-layers` and `layer-status` know the
  `restyle` state, and `.claude/settings.json` allow-lists
  `docker compose run --rm pipeline --style-only`. Tests: `style_only.bats`
  (10 tests), and `status.bats` and `run.bats` updated.

- Low-zoom generalisation for polygon layers (#63), optional and off by
  default: `LAYER_GENERALISE_MAX_ZOOM`, `LAYER_GENERALISE_MIN_PART_PX`
  (default 4) and `LAYER_GENERALISE_SIMPLIFY_PX` (default 1), in screen
  pixels per zoom. Up to that zoom, GDAL drops polygon parts under the
  threshold (each feature keeps its largest, so the drop guard holds) and
  simplifies borders with `gdal vector simplify-coverage`; the zooms are
  tagged for tippecanoe and tiled in the same run as the full-detail
  zooms above. Chosen over tippecanoe flags alone, whose tiny polygon
  reduction keeps islands as area-preserving square dots and whose
  simplification has one tolerance for all zooms; measurements in design
  note 02. New `pipeline/lib/generalise.sh`, tests in `generalise.bats`
  with a synthetic island coverage.

- Binary raster layers, display only (#50, ADR 0008). `LAYER_TYPE=raster`
  in `<layer>.env` (with `LAYER_MIN_ZOOM`, `LAYER_MAX_ZOOM` up to 14, and
  optional `LAYER_NODATA`) builds `<layer>.pmtiles` of grey PNG tiles whose
  level is the share of each pixel covered by 1 cells: gdalwarp to
  EPSG:3857 at the max zoom, the share averaged per lower zoom, `gdal
  raster tile` per zoom, packed with `sqlite3` (now in the pipeline image)
  and `pmtiles convert`. The display config's new raster shorthand
  (`geometry: "raster"`, `color`, `opacity`, `label`) becomes a MapLibre
  `color-relief` layer on a `raster-dem` source, so the colour lives in the
  style, not the tiles, and low zooms show cover density as transparency.
  Chosen over colour-baked PNG tiles and `gdal_translate -of MBTiles` after
  a timed trial on a 300 km clip (6.0 s and 23 MB against 7.7 s and 28 MB,
  and 26.5 s with no density at low zooms); numbers in the ADR. Manifest
  entries gain `type`, `format`, `build_seconds` and `bytes`, and raster
  entries a tile report; the web app reads `type` (missing means vector),
  adds the raster source and layer, a single-swatch legend and the
  visibility toggle, and never makes rasters clickable. Layer configs
  `forest` and `agriculture` point at the November 2026 play data through
  the new `RAW_DIR` setting (compose mounts `${RAW_DIR:-./data/raw}`
  read-only); `.gitignore` gains `*.tif`, `*.tiff`, `*.vrt`, `*.gdb/` and
  `data/work/`. Tests: `raster.bats` (13 tests on synthetic rasters made at
  test time; 73 bats tests in all), a raster case in `status.bats`
  (`--status` shows `type`, `format` and `tile_count`; `--remove` works for
  rasters too) and web tests for the raster path.
- Pipeline `--status` and `--remove`, and Claude Code skills for most
  pipeline and app tasks (#54). `run.sh --status [--json] [layer ...]`
  (alias `--list`, read only, `lib/status.sh`) lists every configured or
  built layer as `current`, `stale` (its `.env`, `.style.json` or source
  data, including shapefile sidecars or the zip, is newer than the
  manifest's `built_at`, or the archive is missing), `not built`,
  `invalid` (the `.env` does not load, no `.style.json`, or no source
  data) or `orphan` (built, config gone), with notes, build time, archive
  size, zooms, feature count and largest tile. `run.sh --remove layer ...`
  drops each layer's manifest entry (atomically, `manifest_remove`), then
  its archive, and rewrites `style.json`; configs are left to `git rm`.
  Tested in `status.bats` (59 bats tests in all). New project skills
  `build-layers`, `layer-status`, `update-layer-data`, `remove-layer`,
  `inspect-data`, `run-map` and `run-checks` call only documented
  commands; the README gains "Using Claude Code (optional)" with a table
  of each task's plain command and skill, and "Removing a layer";
  `CONTRIBUTING.md` says how to add or change a skill.
  `.claude/settings.json` allows the status, inspect, build, map,
  screenshot and check commands, and puts `--remove` on the `ask` list.
- Claude Code skills and helpers for adding and restyling layers (#41).
  Project skills `add-layer` and `restyle-layer` in `.claude/skills/`.
  `pipeline/bin/inspect.sh` (in the pipeline image, on its `PATH`):
  a summary of a source dataset (layers, feature count, geometry type, CRS,
  WGS84 extent, shapefile encoding, field stats and low-cardinality values,
  feature id candidates, and for polygons invalid geometries, union parts
  and holes, overlap and GDAL's coverage check), as text or `--json`, with
  hints for the layer config; tested in `inspect.bats`.
  `scripts/screenshot.sh`: screenshots of the map at given `zoom/lat/lon`
  views on the light and dark basemaps, from a private copy of the web image
  (`erap-map-web:screenshot`) on a spare port (8090 up) and a pinned
  Playwright image (`mcr.microsoft.com/playwright:v1.55.0-noble`, by
  digest) on a private network, both removed afterwards; output in the
  git-ignored `tmp/screenshots/`. The web map keeps its view in the URL hash
  (`#zoom/lat/lon`, MapLibre `hash`), which the screenshots use and which
  makes a view shareable. `.claude/settings.json` allows the pipeline run,
  `inspect.sh` and `screenshot.sh`.

- Data-driven layer styles (#39, ADR 0007). Each layer gains
  `pipeline/layers/<layer>.style.json`: `title`, `defaultVisible`, `order`
  (draw order, default 0, ties by name), `popup`, and either the `symbology`
  shorthand or raw MapLibre style-spec `layers` (no `source`; ids prefixed
  with `<layer>-` on the map), an optional explicit `legend`, and optional
  `breaks` (`quantile` or `equal`) on a stepped colour, computed from the
  data. One JSON Schema, `pipeline/schema/layer-style.schema.json`, is used
  by the pipeline and by the web app's tests. The pipeline image gains Node
  (from the same pinned image as the web build) and a small tool,
  `pipeline/style/` (ajv 8.17.1, `@maplibre/maplibre-gl-style-spec` 26.6.0,
  pinned by lockfile), that validates each config (schema, legend, MapLibre
  style validator) before tiling, failing the layer and keeping the
  previous archive and manifest entry on any problem, and writes the
  resolved config into its `manifest.json` entry as `display`. The pipeline
  also writes `data/tiles/style.json`, a standalone MapLibre style of the
  data layers (`pmtiles://` sources, no basemap). The web app no longer
  defines any layer: it fetches `manifest.json` at startup and builds the
  layer list, style layers, legends, pop-ups and draw order from it, with a
  message in the layer panel if the manifest is missing or invalid;
  `web/src/layers/sample.ts`, `samplePoints.ts`, the registry and the
  symbology generator (now in the pipeline tool) are removed, and `sample`
  and `sample_points` look and behave as before. Compose mounts
  `pipeline/layers/` into the pipeline container, so a layer change needs
  only a pipeline run and a reload. Tests: `display.bats` and the tool's
  node:test suite (40 bats tests in all), and web tests for the manifest
  reader and its agreement with the schema.
- Coverage-safe tiling, drop guard and shapefile input options for the
  pipeline (#36). `LAYER_PROFILE=coverage` adds
  `--no-simplification-of-shared-nodes` (chosen over the deprecated
  `--detect-shared-borders`, which left a hole at z5 of the test fixture)
  and `--drop-smallest-as-needed`; `LAYER_TIPPECANOE_FLAGS` add to it. Every
  layer now goes through a visibility-aware drop guard (`lib/guard.sh`):
  each feature's largest polygon part is measured once in EPSG:3857, and the
  build fails, keeping the previous archive, if a feature covering at least
  `LAYER_MIN_VISIBLE_PX` (default 1) screen pixels at 256 px tiles is missing
  at any zoom; smaller missing features are logged. `manifest.json` entries
  gain `profile`, `min_visible_px`, `max_tile_bytes` and per-zoom `zooms`
  stats (input, present, required, required present, largest tile); the
  existing fields are unchanged. New layer options `LAYER_SOURCE_SRS`
  (`-s_srs`) and `LAYER_ENCODING` (open option `ENCODING`), and `.zip`
  inputs read in place through `/vsizip/`. tippecanoe now always gets
  `--read-parallel`. Tests: `coverage.bats` (a generated synthetic coverage
  fixture, `make_coverage.sh`; gap check at z0 to z6 that fails without the
  shared-nodes flag; large features at every zoom; manifest stats; guard
  failures) and `inputs.bats` (shapefiles without `.prj` or `.cpg`, zipped
  shapefiles, made in the test with `ogr2ogr`), 27 bats tests in all. Design
  notes in `docs/design/01_architecture.md` and
  `docs/design/02_data_layers_and_popups.md`.
- Web layer selector with inline legends (#33): a collapsible "Map layers"
  panel (collapsed by default below 600 px wide) holding the existing Light
  / Dark basemap radio group and a Layers list with one labelled checkbox
  per data layer, topmost first, each with a legend of swatches and labels
  (categories) or ramp steps with ranges. Layer definitions gain
  `defaultVisible` and a typed `symbology` (polygon fill and outline, or
  point circle and stroke; single colour, categorical `match` or stepped
  `step` colouring) from which both the MapLibre paint and the legend are
  generated (`web/src/layers/symbology.ts`). Visibility uses layout
  `visibility`, is kept in React state and re-applied when the data layers
  are re-added after a basemap switch; hidden layers are not queried for
  pop-ups and an open pop-up closes when its layer is hidden. A layer whose
  archive is missing is shown disabled with a short note. `sample` is
  restyled with a four-class YlGnBu ramp on `score` and a thin white
  outline; `sample_points` is added to the registry above it, as circles
  coloured by `category` (Okabe-Ito orange, reddish purple, vermillion)
  with a white stroke and a pop-up showing name, ID, Category and Count.
  Vitest tests cover the paint expressions (validated with
  `validateStyleMin`), legends, registry order and ids, and visibility
  state.
- Second synthetic pipeline layer `sample_points` (#32): 30 made-up points
  over Canada (`id` as the tile feature id; `name`, `category` of `alpha`,
  `beta` or `gamma`, `count` 1 to 500), 8 of them inside `sample` polygons so
  the layers overlap. Deterministic generator
  `pipeline/tests/fixtures/make_sample_points.sh` and committed
  `sample_points.geojson`, config `pipeline/layers/sample_points.env` (zooms
  0 to 10, `--drop-rate=1` so every point is kept at every zoom), bats tests
  for the fixture, layer, zooms, attributes, feature ids at every zoom and a
  default run building both layers into one manifest, and a contract entry
  in `docs/design/02_data_layers_and_popups.md`. The CI shellcheck step
  and its `CONTRIBUTING.md` equivalent now lint every
  `pipeline/tests/fixtures/*.sh`.
- `CONTRIBUTING.md` Setup: prerequisites (Git, Docker with Compose v2, Git
  Bash on Windows), a run block, a Checks block with Docker-only local
  equivalents of every CI job (`pipeline`, `web`, `compose`,
  `repo-hygiene`) and their timings, and how auto-merge treats PRs. The
  `CLAUDE.md` Commands section now lists the real run commands, the CI gates
  and their local and CI timings, and Project status reflects M1 nearly done
  and M2 blocked on #13. The README status line is updated to match.
- CI stack jobs in `ci.yml`, gated on non-docs changes and required through
  `checks`: `pipeline` (shellcheck 0.11.0 and hadolint 2.15.1 from
  checksum-verified release binaries, the bats tests in the `test` image,
  then the `runtime` image), `web` (Node 26.13.0 with npm cache: `npm ci`,
  lint, typecheck, test, build, `npm audit --omit=dev --audit-level=high`,
  hadolint, the web image and a smoke test of `/config.json` and `/`) and
  `compose` (`docker compose config -q`, with and without the `pipeline` and
  `dev` profiles); Docker builds use Buildx with the GitHub Actions cache
  (`mode=max`, scopes `pipeline` and `web`).
- `warm-cache.yml` moved from `workflows-optional/` into `workflows/` and
  filled in: on pushes to `main` that touch `pipeline/` or `web/`, twice a
  week and by hand, it saves the `pipeline` and `web` Docker layer caches and
  the `web/` npm cache from `main`, so new PRs start warm.
- Dependabot entries for npm (`/web`, grouped minor and patch updates for
  runtime and dev dependencies, TypeScript majors ignored while
  typescript-eslint needs `<6.1.0`), docker (`/pipeline`, `/web`) and
  docker-compose (`/`).
- Feature pop-ups in the web app: clicking a feature of a layer with a
  `popup` definition opens a MapLibre pop-up rendered by a React component,
  with a title, labelled and formatted stats, and Chart.js charts built from
  tile attributes and the feature id. Pop-up content is declared per layer in
  `src/layers/` (typed `PopupDefinition`); the `sample` layer shows its name,
  ID, area, score and a bar chart of its yearly values. Pointer cursor over
  clickable features, one pop-up at a time, closes on a click elsewhere, and
  keeps working after a basemap switch. Adds `chart.js` 4.6.1 with only the
  bar, line, scale and tooltip components registered; charts are destroyed
  when the pop-up closes.
- `docker-compose.yml` (ADR 0004): `web` (nginx image
  `natureconservancy/erap-map-web`, port `WEB_PORT` default 8080, tiles
  mounted read-only, `CARTO_API_KEY` from `.env`, read-only root with a tmpfs
  `/tmp`, healthcheck), `pipeline` under the `pipeline` profile (image
  `natureconservancy/erap-map-pipeline`, `data/raw` read-only, `data/tiles`
  read-write, uid overridable with `PIPELINE_UID`/`PIPELINE_GID`), and
  `web-dev` under the `dev` profile (Vite with hot reload in the pinned Node
  image, `node_modules` in a named volume, port `WEB_DEV_PORT` default
  5173); `VITE_USE_POLLING` turns on Vite's polling watcher for Windows bind
  mounts; README usage and `.env.example` updated.
- Web image (`web/Dockerfile`): Node 26.13.0 build stage and unprivileged
  nginx 1.30.6 runtime, both pinned by digest, listening on 8080;
  `web/nginx.conf` serves the app with an `index.html` fallback for app
  routes, `/tiles/` from `/srv/tiles` with range requests,
  `application/vnd.pmtiles`, `no-cache` revalidation and plain 404s, and
  year-long caching for `/assets/`; an entrypoint script writes
  `/config.json` from `CARTO_API_KEY` at start, JSON-escaped.
- CARTO basemaps in the web app (ADR 0005): `src/map/basemap.ts` picks CARTO
  Positron (default) or Dark Matter with the key from the runtime
  `/config.json` (`src/config.ts`), or keyless OpenFreeMap Positron and Dark
  with a console warning when there is no key; a light/dark basemap toggle;
  data layers are re-added after a basemap switch; the Vite dev and preview
  servers serve `/config.json` from `CARTO_API_KEY`.
- Web app scaffold (`web/`): React, TypeScript and Vite, MapLibre GL JS with
  the `pmtiles` protocol, a placeholder OpenFreeMap basemap in `src/map/`, and
  a layer registry in `src/layers/` with the `sample` layer from
  `/tiles/sample.pmtiles`; the Vite dev and preview servers serve
  `data/tiles/` at `/tiles/` with range requests; ESLint, `tsc --noEmit` and
  vitest wired to npm scripts.
- Pipeline entry script `pipeline/bin/run.sh` with shared functions in
  `pipeline/lib/` (logging, layer config, ogr2ogr normalise, atomic
  tippecanoe build, `manifest.json`), the `sample` layer config, a synthetic
  fixture with its generator, and bats tests. The pipeline image now runs
  `run.sh` by default and has a `test` target with bats-core 1.14.0.
- Pipeline image (`pipeline/Dockerfile`): GDAL 3.13.3 base pinned by digest,
  tippecanoe 2.79.0 built from a commit-checked tag, pmtiles CLI 1.31.2
  checksum-verified, non-root user; repo-wide `.hadolint.yaml`.
- Project plan for ERAP Map PoC: project brief, architecture, data contract
  skeleton and milestones in `docs/design/`, and ADRs 0002 to 0004 for the
  pipeline, web app, and Docker Compose stack choices.
- ADR 0005: CARTO Positron and Dark Matter basemaps, with the API key
  supplied at runtime; `.env.example` documents `CARTO_API_KEY`.
- CI: `changes` job so docs-only PRs skip stack jobs, a single required
  `checks` job, a commented cache example, and an opt-in `warm-cache.yml`.
- Hints in `CLAUDE.md`, `CONTRIBUTING.md`, `.gitignore` and the handoff
  template.
- Initial project harness: issue and PR templates, contribution and security
  policies, docs structure (design, decisions, handoffs), and Claude Code
  working rules.

### Changed

- The synthetic `sample` and `sample_points` layers are test layers now
  (#17): their configs moved from `pipeline/layers/` to
  `pipeline/tests/layers/`, so a pipeline run with no layer names builds
  only the real layers. The bats tests copy them from there; for demo tiles
  without any data, run the pipeline with
  `-e PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers`. A test checks that
  no config in `pipeline/layers/` reads the synthetic fixtures.
- Raster layers are one Cloud Optimized GeoTIFF each, built in minutes
  (#62, ADR 0010, superseding the storage part of ADR 0008): a raster
  layer is now `data/tiles/<layer>.cog.tif`, read by the browser with range
  requests through `@geomatico/maplibre-cog-protocol` 0.10.0, in place of
  PNG tiles in a `.pmtiles` archive; vector layers stay PMTiles. A
  full-Canada 30 m raster at z2 to z12 now builds in about 9 to 10
  minutes on a 16-CPU laptop the first time and 5 to 8 minutes after
  (agriculture 0.38 GB, forest 2.27 GB), where ADR 0008 estimated 40
  minutes to over an hour. Each
  raster source is prepared once into a tiled 0/255 Byte GeoTIFF cached
  in `data/work/raster/` (the new `PIPELINE_WORK_DIR`, mounted by
  compose), keyed by the source's path, size and modification time and
  the layer's `LAYER_SOURCE_SRS` and `LAYER_NODATA`; the warp to Web
  Mercator writes ZSTD level 1 over an extent snapped to the tile grid,
  the lower zooms are `gdaladdo -r average` overviews, and
  `gdal_translate -of COG` writes the result (256 px blocks on the map's
  tiles, checked, written atomically). Values stay grey levels 0 to 255
  (the colour ramp runs to 255). The manifest entry has `format` `cog` and
  a COG build report (`width`, `height`, `block_size`, `overview_count`,
  per-zoom sizes) in place of tile counts; `--status` shows the size in
  pixels, lists a raster built as PNG tiles as `stale`, and its rebuild
  deletes the old `.pmtiles`; `--remove` deletes either. The map still
  reads an older raster `.pmtiles`. The COG code loads only when a COG
  layer exists. nginx and the dev server serve `.tif` as `image/tiff`.
  `sqlite3` is gone from the pipeline image. Only binary rasters are
  supported (one band of 0, 1 and nodata); categorical, continuous and
  multiband rasters are left for later. Docs: README sections Tile formats
  and Styling a layer, the data contract, and the add-layer, build-layers,
  layer-status, update-layer-data, remove-layer, restyle-layer,
  inspect-data, run-map and setup skills. Tests: `raster.bats` rewritten
  for the COG (layout, tile grid alignment, values, report, empty raster,
  replacing an older build, `--remove`, the prepare cache), display tool
  and web tests for the `cog://` source.
- README pass (#37): a screenshot of the map (synthetic layers, a pop-up
  open), a project map in place of the template's "What's included", and
  new "Using the map" and "Adding a layer" sections for per-layer `.env`
  and `.style.json` configs. Usage names both synthetic layers and rebuilds
  images with `--build`, since `docker compose run` otherwise reuses a stale
  image after a pull. The auto-merge, branch update and cache warming notes
  move to `CONTRIBUTING.md` (Repo automation).
- Base images in `pipeline/Dockerfile` and `web/Dockerfile` (GDAL, Node,
  nginx) are pinned by tag and digest in literal `FROM` lines instead of
  `ARG ..._IMAGE` defaults, so Dependabot's docker ecosystem can propose
  updates (it does not resolve `ARG` values in `FROM`). The pipeline's GDAL
  stages build from one `gdal` stage, so its pin is in one place (#28).
- Auto-merge and branch updates run from `.github/workflows/` through the NCC
  ConsTech Automation GitHub App (org-level `AUTOMATION_APP_CLIENT_ID`
  variable and `AUTOMATION_APP_PRIVATE_KEY` secret) instead of the template's
  opt-in PAT-based workflows, which are removed from `workflows-optional/`.
  Squash auto-merge is armed on PRs into `main` from branches in this repo,
  never on forks or Dependabot.
- ADR 0001 names files `NNNN-short-title.md`, matching the ADR README.
- `ci.yml` runs on pull requests only; `bootstrap-repo-settings.sh` gates on
  `checks` by default.
- Basemaps are OpenFreeMap Positron (light, the default) and Dark only, with
  no key (ADR 0006, superseding ADR 0005, #31). The map is created straight
  away with the light style; the Light/Dark toggle, the data layers re-added
  after a style switch, and MapLibre's attribution control are unchanged.
- The `web` compose healthcheck fetches `/` instead of `/config.json`.
- The CI web smoke test checks that `/` returns HTML and that the hashed
  MapLibre worker named in the app bundle is served from `/assets/` as
  `application/javascript`, instead of checking `/config.json`.

### Removed

- The CARTO basemap option and its runtime config: `CARTO_API_KEY` (compose
  `web` and `web-dev`, `.env.example`, CI), `/config.json` and the code that
  served or read it (`web/src/config.ts`, `web/vite/serveConfig.ts`, their
  tests, `web/docker/40-write-config-json.sh` and its Dockerfile `COPY`, and
  the `/config.json` location in `web/nginx.conf`), and the console warning
  about the keyless fallback.

### Fixed

- The local web check (`docker compose --profile dev run --rm --no-deps
  web-dev ...`) failed 5 test files because `web-dev` mounted only `web/`
  and the tests read the display schema and expected display fixture from
  `../pipeline` (#52). Compose now mounts `pipeline/schema/` and
  `pipeline/tests/fixtures/` read-only into `web-dev` at the same paths.
- MapLibre worker failed to load ("Worker failed to load") in the built app
  (#26): maplibre-gl builds its worker URL at runtime, so Vite never emitted
  `maplibre-gl-worker.mjs`. `src/map/worker.ts` now imports it with `?url`
  (emitted as a hashed file under `assets/`) and calls `setWorkerUrl` before
  any map is created, and `web/nginx.conf` serves `.mjs` under `/assets/` as
  `application/javascript` with the same cache and `nosniff` headers.
