# Local map config

## Status

Accepted. Extends 0007-data-driven-layer-styles.md: the committed layer
configs stay the shared defaults, and a local file can change them for one
user's map.

## Context

Each user builds and views the map on their own machine, from their own
copy of the source data (no shared sources or hosted tiles for now). Users
want to choose which layers they build and see, point a layer at another
copy of its data, recolour a layer or trim its pop-up, add a layer only
they have, and open the map on their own area, all without editing the
shared files in `pipeline/layers/` or opening a pull request (issue #59).

## Decision

- A **map config**, `map.config.json` at the repo root, git-ignored, with
  `map.config.example.json` committed as a starting point. `MAP_CONFIG` in
  `.env` picks another file (relative to the repo root), so a user can keep
  several and switch. No file means the behaviour before this ADR: every
  committed layer, as it is.
- JSON with a JSON Schema, `pipeline/schema/map-config.schema.json`, like
  the display configs: its `$schema` gives completion and checking in an
  editor, and the pipeline's display config tool checks it with ajv
  (`cli.mjs layers`, `style/mapconfig.mjs`). A local layer's `style` is
  checked against the display config schema by reference.
- What it holds:
  - `enabled` (default: every layer) and `disabled`: which layers are
    built and shown.
  - `overrides`, by layer name: `input` (as `LAYER_INPUT`) and `env`
    (any other `LAYER_*` setting, by name, so new settings need no schema
    change), which change the tiles; and `title`, `order`,
    `defaultVisible` and `style`, which change only the display.
  - `localLayers` (a layer's `env` settings and `style` inline) and
    `layerDirs` (folders of `<layer>.env` plus `<layer>.style.json`, for
    example the git-ignored `pipeline/layers.local/`): layers only this
    user has. A local layer may not reuse a committed name.
  - `map`: the opening `center`, `zoom` and `basemap`.
- **Precedence**, lowest first: the layer's `.env` and `.style.json`
  (committed or local); then the override's `input` and `env`, written as
  bash assignments after the `.env` so they win; the `style` patch, a JSON
  merge patch (RFC 7396: objects merge key by key, lists and other values
  replace, `null` removes a key) over the `.style.json`; then `title`,
  `order` and `defaultVisible`.
- The pipeline resolves the committed layers and the config into the
  effective layer set at the start of every run (every mode, `--status`
  included), and checks it all before anything is built: the schema,
  unknown layer names, missing `layerDirs`, and each changed or local
  display config, with the same checks as `cli.mjs check`. A problem stops
  the run with exit 2 and one line per problem. A layer the config
  changes is built from generated copies of its files in the run's
  scratch dir; the committed files are never written.
- Tiles versus display: `input` and `env` changes need a rebuild;
  everything else, and `enabled`, `disabled` and `map`, is applied by
  `run.sh --style-only`. `--status` tells them apart through hashes of the
  effective settings and display config, stored in the manifest entry's
  `provenance` at build (and display update) time: `stale` versus
  `restyle`, as for the committed files' modification times.
- **Missing sources**: a full build skips a layer whose source data is
  not found, with a warning and a summary, and fails only if nothing could
  be built; a layer named on the command line still fails. `--status`
  shows the new state `source missing`, and `disabled` for a layer the
  config leaves out.
- **Manifest** (the runtime contract of 0007): top-level `map` (the opening
  view and basemap); per entry `enabled` (false for a layer built before
  and since left out: kept, but not shown, so turning it back on needs no
  rebuild) and `provenance` (origin, source path, size and modification
  time, the overrides as applied, and the two hashes), so two users' maps
  can be compared. `style.json` leaves out disabled layers and takes the
  view. The web app still reads only `manifest.json`: it skips disabled
  entries, opens at the map view unless the page URL already has one,
  and starts on the configured basemap.
- Compose mounts the repo read-only at `/repo` in the pipeline container
  and sets `PIPELINE_MAP_CONFIG` to `/repo/${MAP_CONFIG:-map.config.json}`.
  A bind mount of the file itself would not work: Docker makes a missing
  source path into a directory, and the file is optional.

## Consequences

- Each user shapes their own map with one file and plain commands; the
  shared configs, the review process for them and the web app are
  unchanged. Claude Code skills can offer "just for me" (the map config)
  next to "for everyone" (the committed files and a draft pull request).
- The pipeline needs Node for every mode, `--status` included (it is in
  the image).
- The pipeline container sees the whole repo read only, `.env` included.
  It holds only local settings today; a secret added there later would be
  readable by the pipeline (our own code).
- Overrides of `env` are not checked against the list of settings in
  `lib/config.sh`: a typo is ignored like an unknown variable in a `.env`.
- A user's map can differ from the committed one, so screenshots and bug
  reports should say whether a map config was in use; `provenance` in the
  manifest records it.
