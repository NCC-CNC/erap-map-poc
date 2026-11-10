# ERAP Map PoC

A proof of concept for processing spatial data into vector tiles and viewing
them in an interactive web map.

- **Pipeline** (`pipeline/`): bash scripts using GDAL, tippecanoe, and the
  `pmtiles` CLI turn source data in `data/raw/` into one `.pmtiles` file per
  layer in `data/tiles/`, plus any summary stats the pop-ups need.
- **Web map** (`web/`): a React + MapLibre GL JS app that loads those layers
  straight from the `.pmtiles` files and opens pop-ups with summary stats and
  Chart.js charts when a feature is clicked.

Both run in their own Docker containers, tied together by
`docker-compose.yml`.

Status: design / pre-build. The source data, styling, and pop-up content are
still to be confirmed. See `docs/design/` for the brief, architecture, and
milestones, and `docs/decisions/` for the ADRs.

## Usage (planned)

Requires Docker with Docker Compose. These commands arrive in milestone M1.

```sh
# Build tiles from data/raw/ (all layers, or name the ones you want)
docker compose run --rm pipeline

# Run the web map at http://localhost:8080
docker compose up web
```

## Auto-merge and branch updates

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

## Cache warming (optional)

`.github/workflows-optional/warm-cache.yml` saves a cache from `main`, because
a PR can read caches saved on `main` but not caches saved by another PR. Use it
if a CI job downloads something slow on every run. Move it into
`.github/workflows/`, fill in the two placeholders, and use the same path and
key in the `actions/cache` step of your CI job.

## What's included

- `CLAUDE.md`: working rules and durable context, loaded automatically by
  Claude Code.
- `.claude/settings.json`: default tool permissions for Claude Code sessions
  in this repo.
- `docs/design/`: design notes, starting with a project brief template.
- `docs/decisions/`: Architecture Decision Records (ADRs).
- `docs/handoffs/`: session handoff template for continuity between work
  sessions.
- `.github/`: issue forms, PR template, Dependabot config, a stack-neutral CI
  workflow (docs-only PRs skip stack jobs, one required `checks` status),
  app-based auto-merge and branch-update workflows, and an optional
  cache-warming workflow.
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `LICENSE`.
- `scripts/bootstrap-repo-settings.sh`: one-time repo settings setup (branch
  protection, auto-merge, labels) that a template cannot carry over on its
  own.

## License

GNU General Public License v3.0. Replace with your own choice if different.
