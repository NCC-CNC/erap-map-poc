---
name: run-checks
description: Run the CI gates locally in Docker before pushing - shellcheck, hadolint, the pipeline bats tests, the display config check, web lint, typecheck, tests and build, npm audit, compose config, actionlint, markdownlint and the em dash check - and report what failed and how to fix it. Use when asked to run the checks, tests, lint or CI locally, or whether a change is ready to push.
---

# Run the checks

The commands are in `CONTRIBUTING.md` (Checks), one block per CI job,
with the same tools and versions as `.github/workflows/ci.yml`. Read that
section and run its commands from the repo root in Git Bash; do not
retype them from memory. Only Docker is needed.

## 1. Pick the jobs

From `git status` and `git diff --name-only main...`:

- Only `docs/` or `*.md` changed: the repo-hygiene job only (that is all
  CI runs).
- `pipeline/`, `scripts/*.sh` or a Dockerfile: the pipeline job.
- `web/`, or `pipeline/schema/` or `pipeline/tests/fixtures/` (the web
  tests read them): the web job.
- `docker-compose.yml` or `.env.example`: the compose job.
- `pipeline/layers/*.style.json`: also the display config check from
  `CONTRIBUTING.md` (Adding or changing a layer).

When unsure, or before marking a PR ready, run all four jobs.

## 2. Run

Start with `export MSYS_NO_PATHCONV=1` and the `repo=...` line from the
block. Run each command on its own so a failure is easy to place; keep
going after a failure so the report is complete. Timings: the first
pipeline image build takes about 4 minutes (tippecanoe compiles), then
seconds; the web checks take about 15 seconds after the first `npm ci`.

The block's `docker compose build pipeline` and `docker compose build
web` refresh the local images that compose runs, which is wanted here.
Create no other image tags, and leave no containers behind (every
command uses `--rm`).

## 3. Report

A short table: job, check, pass or fail. For each failure, the file and
line and the message (shellcheck code, ESLint rule, failing test name,
markdownlint rule, em dash location) and the fix. Fix only when asked,
or when the fix is mechanical and in files the current change already
touches; rerun the failed check after a fix. Say when everything passes.
