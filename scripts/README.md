# Scripts

Helpers run on the host, from the repo root, in Git Bash on Windows or
any bash. Each has `--help`. Their bats tests are in `tests/` and run in
the pipeline test image with stub `docker` and `gh` (`CONTRIBUTING.md`,
Checks).

| Script | What | Run |
| --- | --- | --- |
| `setup.sh` | first-time setup on Windows 11: checks Git Bash, Docker Desktop, `.env`, `RAW_DIR` and the ports; `--init` also writes `.env`, builds the images and layers and starts the map | `scripts/setup.sh [--check \| --init]` |
| `screenshot.sh` | screenshots of the map at `zoom/lat/lon` views, light and dark, into `tmp/screenshots/`; can click a feature, pick a colour theme or a dialog tab. Runs a private web container and a pinned Playwright image, then removes them | `scripts/screenshot.sh -n NAME VIEW...` |
| `screenshot.cjs` | the Playwright script `screenshot.sh` runs in its container | (not run directly) |
| `publish-pages.sh` | publishes the GitHub Pages copy: checks `data/pages/` (committed layers only, the public protected areas source, under 1 GB), uploads it to the `pages-data` release and starts the Pages workflow (ADR 0014) | `scripts/publish-pages.sh [--dry-run]` |
| `check-tiles-cache.sh` | checks that nginx makes the browser revalidate `style.json` and `build.json`, so a reload picks up a rebuild; run by the CI web smoke test | `scripts/check-tiles-cache.sh BASE_URL TILES_DIR` |
| `bootstrap-repo-settings.sh` | one-off for a new repo from this template: branch protection, auto-merge and labels (needs `gh` with admin rights) | `scripts/bootstrap-repo-settings.sh [owner/repo]` |

Logic that a Claude Code skill needs goes here or in the pipeline, with
tests, never in the skill.
