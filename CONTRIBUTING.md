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

```sh
git clone https://github.com/NCC-CNC/erap-map-poc.git && cd erap-map-poc
cp .env.example .env                      # optional: ports, Linux UIDs

docker compose run --rm --build pipeline  # build tiles into data/tiles/
docker compose up -d --build web          # map at http://localhost:8080
docker compose --profile dev up web-dev   # or Vite with hot reload on :5173
```

See `README.md` (Usage) for ports, `.env` settings, rebuilding images after
a pull, and Linux file ownership.

### Adding or changing a layer

A layer is `pipeline/layers/<layer>.env` (input and tiling) plus
`pipeline/layers/<layer>.style.json` (title, draw order, style, legend,
pop-up), described in `docs/design/02_data_layers_and_popups.md` and ADR
0007, with a step-by-step guide in `README.md` (Adding a layer). Nothing in
`web/` changes: the map reads every layer from `data/tiles/manifest.json`.
Rerun the pipeline for that layer and reload the page; compose mounts
`pipeline/layers/`, so neither image needs a rebuild. Check display configs
without building:

```sh
docker compose run --rm --entrypoint sh pipeline -c \
  'node /opt/pipeline/style/cli.mjs check /opt/pipeline/layers/*.style.json'
```

With Claude Code, the `add-layer` and `restyle-layer` skills
(`.claude/skills/`) walk through this. Their helpers also work by hand:

```sh
# Summarise a source dataset (path relative to data/raw/; --json for more)
docker compose run --rm --build --entrypoint inspect.sh pipeline my/data.shp
# Screenshot the map at zoom/lat/lon views, light and dark basemaps,
# into tmp/screenshots/ (a private web container on port 8090 or higher)
scripts/screenshot.sh -n mylayer 4/55/-110 8/53.9/-114.2
```

### Checks

Every check below is a CI gate: the `ci.yml` jobs feed the one required
status, `checks`, and a PR merges only when it passes. A PR that touches
only `docs/` and Markdown runs just `repo-hygiene`. These commands run the
same tools at the same versions as CI, all in Docker:

```sh
# Git Bash on Windows: stop MSYS rewriting container paths like /mnt.
export MSYS_NO_PATHCONV=1
repo=$(pwd -W 2>/dev/null || pwd)   # Windows path in Git Bash, else $PWD

# pipeline job: shellcheck, hadolint, bats (48 tests, including the display
# tool's node:test unit tests), runtime image
docker run --rm -v "$repo":/mnt -w /mnt koalaman/shellcheck:v0.11.0 -x \
  pipeline/bin/*.sh pipeline/lib/*.sh pipeline/layers/*.env \
  pipeline/tests/fixtures/*.sh pipeline/tests/*.bats scripts/screenshot.sh
docker run --rm -v "$repo":/mnt -w /mnt hadolint/hadolint:v2.15.1 \
  hadolint --config .hadolint.yaml pipeline/Dockerfile web/Dockerfile
docker build --target test -t erap-map-pipeline:test pipeline
docker run --rm erap-map-pipeline:test
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
web smoke test of the nginx image is CI only); see the Commands section of
`CLAUDE.md` for CI timings.

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
