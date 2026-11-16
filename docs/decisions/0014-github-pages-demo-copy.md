# A slimmed-down copy of the map on GitHub Pages

## Status

Accepted. Extends 0004-docker-compose-and-static-pmtiles.md (another static
host for the same files) and 0009-local-map-config.md (a committed map
config, and a `requiredInputs` guard in the schema).

## Context

The map runs locally (ADR 0004). People who do not run Docker should be
able to try it, so a demo copy goes on GitHub Pages (#87). The full-detail
data stays local and may move to blob hosting later. Limits and facts that
shape the copy:

- A Pages site is at most 1 GB. Pages caches files for 10 minutes and
  serves byte ranges, which PMTiles and COG reads need.
- The repo is public, so the site and anything attached to a release are
  public too. Licences and provenance are deferred for the PoC (#13).
- Real data never goes in git (CLAUDE.md), and git rejects files over
  100 MB. A release asset may be up to 2 GB.
- The local forest COG is 2.3 GB at z12, so a full copy does not fit.
- The local protected areas source (`protected_areas.gdb`) holds
  confidential records. A public copy must use CPCAD with them removed
  (`ProtectedConservedArea_2025.gdb`, layer
  `ProtectedConservedArea_2025`, 22,438 features, `OBJECTID` as id).

## Decision

- **Smaller data, from a committed config.** `map.config.pages.json` (a
  map config, schema `pipeline/schema/map-config.schema.json`) builds the
  committed layers with the raster layers at `LAYER_MAX_ZOOM` 10 (about a
  sixteenth of z12; the warp averages, ADR 0010, so roads and field edges
  stay visible) and `protected_areas` from the public CPCAD source.
  Vector layers keep their zooms while the total fits. At z10 with 256
  grey levels forest was 757 MB and agriculture 143 MB, close to the
  limit, so the raster layers also use `LAYER_GREY_LEVELS` 8 (ADR 0010,
  #92), which about halves them (agriculture's z10 level: 94 MB to
  49 MB).
- **Its own output folder.** The compose service `pipeline-pages` is the
  pipeline with that config and `data/pages/` (git-ignored) mounted as its
  output: `docker compose run --rm pipeline-pages`. It never writes
  `data/tiles/` and never reads `MAP_CONFIG` or the user's
  `map.config.json`. The raster cache in `data/work/` is shared, so a
  prepared source is reused.
- **A guard against the wrong source.** A new map config key,
  `requiredInputs` (layer name to source), makes a build fail before
  anything is built if a named layer is not enabled, resolves to another
  input (after the overrides), or has no source data in a full build. The
  Pages config requires `protected_areas` from
  `ProtectedConservedArea_2025.gdb`.
- **Release assets, not git.** `scripts/publish-pages.sh` (needs `gh`
  signed in) checks the folder (manifest, style and every archive named;
  committed layers only; `protected_areas` recorded in the manifest as
  built from the public source; at most 1 GB, a warning over 800 MB),
  uploads only those files to a fixed release, `pages-data` (created if
  missing, never marked latest), with `--clobber`, removes assets no
  longer built and starts the workflow. `--dry-run` checks and lists
  without changing anything.
- **Deploy with Actions.** `.github/workflows/pages.yml`
  (`workflow_dispatch` only, from `main`) builds the app with the site's
  base path (`npm run build -- --base /erap-map-poc/`), downloads the
  release assets into `dist/tiles/` and deploys with
  `actions/upload-pages-artifact` and `actions/deploy-pages`. The base
  path is a build option only: local, nginx and dev builds keep `/`. The
  app already reads `<base>tiles/` and uses a hash view, so it needs no
  SPA fallback.
- **One-off setup** (repo admin): Settings, Pages, Source: GitHub Actions.

## Consequences

- Anyone with the link sees the map without Docker. The copy is coarser:
  rasters stop at z10 (about 150 m pixels at the equator, 75 to 100 m
  across Canada) and the map overzooms past it.
- Publishing is a deliberate act by a maintainer, after checking
  licences (#13). Everything on the site and in the release is public.
- The public protected areas source is unmerged CPCAD, so where areas
  overlap their translucent fills stack and draw darker than in the local
  map, which uses a dissolved source.
- A change to the app needs a workflow run to reach the site, and a data
  change needs `publish-pages.sh`; neither runs on a push. Pages caches
  for 10 minutes, so a new deployment can take that long to show.
- If the data outgrows 1 GB, or needs to be private, host the archives in
  Azure Blob Storage (range requests, CORS) and point the app's tiles URL
  there; the build and the checks stay the same.
