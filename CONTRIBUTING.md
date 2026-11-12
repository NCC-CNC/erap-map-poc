# Contributing

Feedback, bug reports, and ideas are welcome through GitHub issues.

The workflow is:

1. Branch from `main` (one short-lived branch per change).
2. Keep changes small and focused.
3. Run the project checks locally before pushing (lint, tests, build). See
   Checks below for the exact commands.
4. Open a pull request into `main`. CI must pass before merge, and a ready
   PR merges itself when it does (see Pull requests below).

## Setup

Prerequisites: Git and Docker with Docker Compose v2. Nothing else (no Node,
GDAL or tippecanoe) is needed on the host. On Windows, use Git Bash: the
`bash` in PowerShell may be WSL, without `gh` or your Git credentials.

`scripts/setup.sh --init` does the first-time steps below for you (README,
Getting started): it checks the machine, writes `.env`, builds the images
and the layers whose source data it finds, and starts the map.
`scripts/setup.sh` alone only checks (Docker Desktop, WSL 2, resources,
disk, `.env`, `RAW_DIR`, ports, line endings) and changes nothing. By hand:

```sh
git clone https://github.com/NCC-CNC/erap-map-poc.git && cd erap-map-poc
cp .env.example .env                      # optional: ports, Linux UIDs, RAW_DIR
cp map.config.example.json map.config.json   # optional: your own map (README)

# Demo tiles into data/tiles/ from the synthetic test layers (no data needed)
docker compose run --rm --build -e PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers pipeline
docker compose up -d --build web          # map at http://localhost:8080
docker compose --profile dev up web-dev   # or Vite with hot reload on :5173
```

See `README.md` (Usage) for ports, `.env` settings, rebuilding images after
a pull, and Linux file ownership.

Real source data stays outside the repo: set `RAW_DIR` in `.env` (or the
shell) to the folder holding it, which compose mounts read-only at
`/data/raw`, then build a layer by name, for example
`docker compose run --rm pipeline forest`. Never copy data into the repo;
`.gitignore` covers `data/raw/`, `data/tiles/`, `data/work/`, `*.tif`,
`*.tiff`, `*.vrt` and `*.gdb/`, but check `git status` before each commit.

### Adding or changing a layer

A layer is `pipeline/layers/<layer>.env` (input and tiling) plus
`pipeline/layers/<layer>.style.json` (title, draw order, style, legend,
pop-up), described in `docs/design/02_data_layers_and_popups.md`, ADR 0007
and, for binary raster layers (`LAYER_TYPE=raster`), ADR 0008, with a
step-by-step guide in `README.md` (Adding a layer). Nothing in `web/`
changes: the map reads every layer from `data/tiles/manifest.json`. Rerun
the pipeline for that layer and reload the page; compose mounts
`pipeline/layers/`, so neither image needs a rebuild. A change to
`<layer>.style.json` only (colours, legend, pop-up, title, order,
visibility, for vector and raster layers) needs no re-tiling:
`docker compose run --rm pipeline --style-only <layer>` updates the
manifest entry and `style.json` in seconds. A change for your own map
only (fewer layers, your copy of the data, other colours, a layer only
you have, the opening view) goes in your git-ignored `map.config.json`
instead, with no pull request: see `README.md` (Your map config) and ADR
0009. Check display configs without building:

```sh
docker compose run --rm --entrypoint sh pipeline -c \
  'node /opt/pipeline/style/cli.mjs check /opt/pipeline/layers/*.style.json'
```

Helpers for checking a layer by hand (Claude Code's skills use the same
ones, see below):

```sh
# Summarise a source dataset (path relative to data/raw/; --json for more)
docker compose run --rm --build --entrypoint inspect.sh pipeline my/data.shp
# What is built and what is stale; apply a .style.json change without
# re-tiling; remove a layer's build (README.md)
docker compose run --rm pipeline --status
docker compose run --rm pipeline --style-only mylayer
docker compose run --rm pipeline --remove mylayer
# Screenshot the map at zoom/lat/lon views, light and dark basemaps,
# into tmp/screenshots/ (a private web container on port 8090 or higher)
scripts/screenshot.sh -n mylayer 4/55/-110 8/53.9/-114.2
```

### Adding or changing a Claude Code skill

Claude Code is optional (`README.md`, Using Claude Code). Its project
skills live in `.claude/skills/<name>/SKILL.md`. To add or change one:

- Procedure only, logic in scripts. A skill says which documented
  commands to run, in what order, and what to check in their output. If
  it needs something no command does yet (a new check, a report, a
  change to files), add that to the pipeline (`pipeline/bin/run.sh`,
  `pipeline/lib/`, with bats tests) or `scripts/` first, with shellcheck
  and docs, then call it from the skill.
- Keep it short (under about 80 lines), with `name` (the folder name) and
  a `description` frontmatter that says what it does and the natural
  requests it should answer, since that is how Claude Code picks it.
- Follow the data and Docker rules: no input or output data in git,
  draft PRs only, no extra image tags, `--rm` on every container.
- Keep the README table (Using Claude Code) in step: every skill has a
  row with the plain command, so the task can be done without Claude
  Code.
- `.claude/settings.json` allow-lists read-only and build commands only.
  Never allow-list a destructive one; `--remove` is on the `ask` list so
  it always prompts. Never put a wildcard before the image name in a
  `docker run` rule: it would also match `--entrypoint` or extra mounts.

### Checks

Every check below is a CI gate: the `ci.yml` jobs feed the one required
status, `checks`, and a PR merges only when it passes. A PR that touches
only `docs/` and Markdown runs just `repo-hygiene`. These commands run the
same tools at the same versions as CI, all in Docker:

```sh
# Git Bash on Windows: stop MSYS rewriting container paths like /mnt.
export MSYS_NO_PATHCONV=1
repo=$(pwd -W 2>/dev/null || pwd)   # Windows path in Git Bash, else $PWD

# pipeline job: shellcheck, hadolint, bats (94 tests, including the display
# tool's node:test unit tests; 41 more for scripts/setup.sh), runtime image
docker run --rm -v "$repo":/mnt -w /mnt koalaman/shellcheck:v0.11.0 -x \
  pipeline/bin/*.sh pipeline/lib/*.sh pipeline/layers/*.env \
  pipeline/tests/layers/*.env pipeline/tests/fixtures/*.sh pipeline/tests/*.bats scripts/screenshot.sh \
  scripts/check-tiles-cache.sh scripts/setup.sh scripts/tests/*.bats
docker run --rm -v "$repo":/mnt -w /mnt hadolint/hadolint:v2.15.1 \
  hadolint --config .hadolint.yaml pipeline/Dockerfile web/Dockerfile
docker build --target test -t erap-map-pipeline:test pipeline
docker run --rm erap-map-pipeline:test
docker run --rm -v "$repo":/repo:ro erap-map-pipeline:test /repo/scripts/tests
docker compose build pipeline

# web job: npm ci, lint, typecheck, test, build, audit (Node 26.13.0)
docker compose --profile dev run --rm --no-deps web-dev sh -c 'npm ci &&
  npm run lint && npm run typecheck && npm test && npm run build &&
  npm audit --omit=dev --audit-level=high'
docker compose build web

# compose job
docker compose config -q
docker compose --profile pipeline --profile dev config -q

# repo-hygiene job: actionlint, markdownlint, no em dashes
docker run --rm -v "$repo":/repo -w /repo rhysd/actionlint:1.7.7 -color
docker run --rm -v "$repo":/repo -w /repo node:26.13.0-bookworm-slim \
  npx --yes markdownlint-cli '**/*.md' --ignore node_modules --ignore LICENSE
! git grep -In $'\xe2\x80\x94' -- . ':!LICENSE'
```

The first pipeline image build takes about 4 minutes (it compiles
tippecanoe); later builds are cached and take seconds. The web checks take
about 15 seconds once the Node image is pulled. CI runs the same steps (the
web smoke test of the nginx image is CI only, including
`scripts/check-tiles-cache.sh`, which checks that a reload picks up a new
`manifest.json` and `style.json`); see the Commands section of `CLAUDE.md`
for CI timings.

### Pull requests

The NCC ConsTech Automation app arms auto-merge on every non-draft PR from a
branch in this repo, so the PR merges itself as soon as `checks` passes. If
it is not ready, open it as a draft and mark it ready for review later. PRs
from forks and from Dependabot merge by hand. See Repo automation below.

## Repo automation

For maintainers. None of this is needed to use the map or add data.

### Auto-merge and branch updates

Two workflows in `.github/workflows/` make green PRs merge themselves. Both
act through the NCC ConsTech Automation GitHub App, owned by the `NCC-CNC`
org, so there is no personal access token to create or rotate.

- `auto-merge.yml` arms squash auto-merge on every PR into `main` opened from
  a branch in this repo (pushing one needs write access, so this covers the
  owner and maintainers) and brings the PR level with `main`. PRs from forks
  and from Dependabot are never armed and merge by hand. A draft is armed
  when it is marked ready for review.
- `update-branches.yml` updates every armed PR after each push to `main`, so
  strict "up to date" branch protection does not leave them stuck BEHIND.

One-time setup (org or repo admin):

- Install the NCC ConsTech Automation app on this repo.
- Give this repo access to the org-level `AUTOMATION_APP_CLIENT_ID` variable
  (the app's Client ID, not its App ID) and the org-level
  `AUTOMATION_APP_PRIVATE_KEY` secret; both are shared with selected
  repositories.
- Turn on "Allow auto-merge" in the repo settings
  (`scripts/bootstrap-repo-settings.sh` does this).

`GITHUB_TOKEN` cannot be used because GitHub starts no workflows for pushes or
merges made with it: "Closes #N" would not close issues, and the PR's checks
would never run on an updated branch. `ci.yml` runs on PRs only: with strict
protection every PR is tested against current `main` before it merges.

### Cache warming

`.github/workflows/warm-cache.yml` saves the CI caches from `main`, because a
PR can read caches saved on `main` but not caches saved by another PR. It
builds the pipeline `test` image and the web image with the same Docker
layer cache scopes as `ci.yml` (`pipeline`, `web`), so a new PR does not
rebuild tippecanoe from source, and fills the npm cache for `web/`. It runs
on pushes to `main` that touch `pipeline/` or `web/`, twice a week (unused
caches expire after 7 days), and by hand. If you change a cache scope or
build setting in `ci.yml`, change it here too.

## Conventions

- Conventional Commits (for example `feat: ...`, `fix: ...`, `chore: ...`,
  `docs: ...`).
- No em dashes in code, comments, docs, commit messages, or user-facing text.
- See `CLAUDE.md` for the full working rules and `docs/` for design notes and
  decision records.
