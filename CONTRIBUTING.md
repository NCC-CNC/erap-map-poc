# Contributing

Feedback, bug reports and ideas are welcome through GitHub issues.

1. Branch from `main` (or `dev` while the refactor is there), one
   short-lived branch per change.
2. Keep changes small and focused, and update the docs with them.
3. Run the checks below before pushing.
4. Open a pull request. CI must pass; a ready PR into `main` merges itself when it
   does.

## Setup

Git and Docker with Compose v2; nothing else on the host. On Windows use
Git Bash (the `bash` in PowerShell may be WSL, without `gh` or your Git
credentials). `scripts/setup.sh --init` does the first-time steps
(README, Getting started). By hand:

```sh
git clone https://github.com/NCC-CNC/erap-map-poc.git && cd erap-map-poc
cp .env.example .env                          # optional: RAW_DIR, ports, Linux UIDs
cp map.config.example.yaml map.config.yaml    # optional: your own map
MSYS_NO_PATHCONV=1 docker compose run --rm --build \
  -e PIPELINE_LAYERS_DIR=/opt/pipeline/tests/layers pipeline   # test layers, no data needed
docker compose up -d --build web              # http://localhost:8080
docker compose --profile dev up web-dev       # or Vite with hot reload on :5173
```

Where things are: `docs/how-it-works.md`, and the READMEs in `pipeline/`,
`scripts/` and `web/`. Tasks on layers are in `docs/guide.md`; the
layer file format in `docs/layer-file.md`.

Real data stays outside the repo (`RAW_DIR`). `.gitignore` covers
`data/`, `*.tif`, `*.vrt` and `*.gdb/`, but check `git status` before
each commit. A layer PR holds its layer file only.

## Checks

Every check is a CI gate: the `ci.yml` jobs feed the one required status,
`checks`. A PR that touches only `docs/` and Markdown runs just
`repo-hygiene`. Same tools and versions as CI, all in Docker:

```sh
# Git Bash on Windows: stop MSYS rewriting container paths like /mnt.
export MSYS_NO_PATHCONV=1
repo=$(pwd -W 2>/dev/null || pwd)   # Windows path in Git Bash, else $PWD

# pipeline job: shellcheck, hadolint, bats (pipeline and scripts/, with
# stub docker and gh), the map configs against their schema, runtime image
docker run --rm -v "$repo":/mnt -w /mnt koalaman/shellcheck:v0.11.0 -x \
  pipeline/bin/*.sh pipeline/lib/*.sh \
  pipeline/tests/fixtures/*.sh pipeline/tests/*.bats pipeline/tests/*.bash scripts/screenshot.sh \
  scripts/check-tiles-cache.sh scripts/setup.sh scripts/publish-pages.sh scripts/tests/*.bats
docker run --rm -v "$repo":/mnt -w /mnt hadolint/hadolint:v2.15.1 \
  hadolint --config .hadolint.yaml pipeline/Dockerfile web/Dockerfile
docker build --target test -t erap-map-pipeline:test pipeline
docker run --rm erap-map-pipeline:test
docker run --rm -v "$repo":/repo:ro --entrypoint jv erap-map-pipeline:test \
  /opt/pipeline/schema/map.schema.json /repo/map.pages.yaml /repo/map.config.example.yaml
docker run --rm -v "$repo":/repo:ro erap-map-pipeline:test /repo/scripts/tests
docker compose build pipeline

# web job: npm ci, lint, typecheck, test, build, audit (Node 26.13.1)
docker compose --profile dev run --rm --no-deps web-dev sh -c 'npm ci &&
  npm run lint && npm run typecheck && npm test && npm run build &&
  npm audit --omit=dev --audit-level=high'
docker compose build web

# compose job
docker compose config -q
docker compose --profile pipeline --profile dev --profile pages config -q

# repo-hygiene job: actionlint, markdownlint, no em dashes
docker run --rm -v "$repo":/repo -w /repo rhysd/actionlint:1.7.7 -color
docker run --rm -v "$repo":/repo -w /repo node:26.13.1-bookworm-slim \
  npx --yes markdownlint-cli '**/*.md' --ignore node_modules --ignore LICENSE
! git grep -In $'\xe2\x80\x94' -- . ':!LICENSE'
```

The first pipeline image build takes about 4 minutes (it compiles
tippecanoe), then seconds; the web checks about 15 seconds. The web smoke
test of the nginx image, with `scripts/check-tiles-cache.sh`, runs in CI
only. A change to `pipeline/schema/layer.schema.json` also needs `npm run
layer-types` in `web/` (a test fails until the generated types match).

## Pull requests

- Conventional Commits (`feat: ...`, `fix: ...`, `docs: ...`,
  `chore: ...`), no em dashes anywhere.
- `Closes #N` in the description where there is an issue.
- Significant decisions get an ADR in `docs/decisions/`; design notes go
  in `docs/design/`.
- A ready PR into `main` from a branch in this repo merges itself when `checks`
  passes; open a draft to hold one for review. PRs into `dev`, from forks and
  from Dependabot merge by hand.

## Claude Code skills

Claude Code is optional. Its skills in `.claude/skills/<name>/SKILL.md`
are thin wrappers: each links to its `docs/guide.md` section and runs the
same documented commands. To add or change one:

- Logic goes in the pipeline or `scripts/`, with tests and docs, never
  in the skill. A skill that needs more than the documented commands is
  a sign a command is missing.
- Keep it to about 40 lines, with `name` and a `description` that says
  what it does and which requests it answers.
- No data in git, `--rm` on every container, no extra image tags.
- Keep the README table (Using Claude Code) in step.
- `.claude/settings.json` allow-lists read-only and build commands only;
  `--remove` always prompts.

## Repo automation

For maintainers; not needed to use the map.

- `auto-merge.yml` arms squash auto-merge on every PR into `main` from a
  branch in this repo and brings it level with `main`; `update-branches.yml`
  updates armed PRs after each push to `main`, so strict protection does
  not leave them behind. Both act through the NCC ConsTech Automation
  GitHub App (no personal token): install it on the repo, give the repo
  the org's `AUTOMATION_APP_CLIENT_ID` variable and
  `AUTOMATION_APP_PRIVATE_KEY` secret, and turn on "Allow auto-merge"
  (`scripts/bootstrap-repo-settings.sh`). `GITHUB_TOKEN` cannot be used:
  GitHub starts no workflows for its pushes.
- `warm-cache.yml` saves the Docker layer and npm caches from `main`
  (PRs can read those, not each other's), on pushes to `pipeline/` or
  `web/`, twice a week and by hand. Keep its cache scopes in step with
  `ci.yml`.
- `pages.yml` builds and deploys the GitHub Pages copy
  (`docs/guide.md`, Publish the GitHub Pages copy).
