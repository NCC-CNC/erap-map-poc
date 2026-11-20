# CLAUDE.md

Rules and pointers for this project. Keep it to direction, not a task
list; open GitHub issues are the task tracker.

## Project

ERAP Map PoC: a bash pipeline turns spatial data into vector tiles
(PMTiles) and binary rasters into COGs, and a read-only web map shows
them, with pop-ups of stats and Chart.js charts on click. Internal for
now; the brief is `docs/design/00_project_brief.md`, the plan
`docs/design/03_milestones.md`, how it fits together `docs/how-it-works.md`.

Status: the refactor (`docs/design/04_refactor.md`, ADR 0015) is done
and merged into `main` (#158), after a full build from the real data and a
check in the browser: one `pipeline/layers/<layer>.yaml` per layer,
`data/tiles/style.json` and `build.json`, `map.config.yaml`. The
four committed layers are `ecoregions` (themes, a dialog), `protected_areas`,
`forest` and `agriculture` (binary rasters, display only). Licences,
provenance and stable ids are deferred (#13); `OBJECTID` is the feature id.

## Scope

In scope: the on-demand pipeline, the read-only map, docker-compose to run
both, and the hand-published GitHub Pages copy (ADR 0014). Not in scope:
production hosting, authentication, a tile server or database, editing,
scheduled runs. Do not expand scope without a design note in `docs/design/`
or an ADR in `docs/decisions/`.

## Hard constraints

- Pin every tool and base image version.
- The web app reads only `data/tiles/` (`style.json` and the archives),
  never `data/raw/`. No layer is defined in `web/`: each is one layer file
  (schema `pipeline/schema/layer.schema.json`).
- A user's own changes go in the git-ignored `map.config.yaml` (schema
  `pipeline/schema/map.schema.json`) or `pipeline/layers.local/`, never in
  committed layer files.
- Derived values and action recommendations are `fields.calculated` in
  the pipeline, never calculated in the app.
- Pipeline writes are atomic (temp file, then move). Secrets come from
  `.env` at runtime, never committed or baked into images.
- Real data, `.pmtiles`, `.cog.tif` and screenshots never go in git.

## Commands

Plain commands are in `docs/guide.md` (tasks) and `CONTRIBUTING.md`
(setup, checks); `pipeline/bin/run.sh --help` and `inspect.sh --help` have
the options. Only Docker is needed. On Windows use Git Bash; container paths
need `MSYS_NO_PATHCONV=1`. Key ones: `docker compose run --rm pipeline
[layer ...]`, `--status`, `--style-only`, `--remove`; `docker compose up -d
--build web` (:8080); `scripts/setup.sh`, `scripts/screenshot.sh`,
`scripts/publish-pages.sh` (run a real publish only when the maintainer
asks).

Gates: the CI jobs `pipeline`, `web`, `compose` and `repo-hygiene` feed the
one required status `checks`; a PR touching only `docs/` and `*.md` runs
just `repo-hygiene`.

## Skills

`.claude/skills/` has 9 skills, each a thin wrapper that links to its
`docs/guide.md` section and runs the same commands. Claude Code stays
optional: new logic goes in the pipeline or `scripts/` with tests, never in
a skill. `remove-layer` always confirms with the user. Skills that change a
layer ask whether it is for the user only (no PR) or for everyone (the
layer file only, in a draft PR).

## Working rules

- Branch from `main` (from `dev` for refactor work); one short-lived branch
  per change; PR with CI passing. Open PRs ready, not draft, unless asked.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).
- No em dashes in code, comments, docs, commit messages or user-facing text.
- Significant decisions get an ADR; design notes go in `docs/design/`.
- Keep changes small; update docs when behaviour or design changes.
