---
name: run-checks
description: Run the CI gates locally in Docker before pushing - shellcheck, hadolint, the pipeline bats tests, the map config check, web lint, typecheck, tests and build, npm audit, compose config, actionlint, markdownlint and the em dash check - and report what failed and how to fix it. Use when asked to run the checks, tests, lint or CI locally, or whether a change is ready to push.
---

# Run the checks

The commands are in `CONTRIBUTING.md` (Checks), one block per CI job,
with the same tools and versions as `.github/workflows/ci.yml`. Read that
section and run its commands from the repo root in Git Bash; do not
retype them from memory.

1. Pick the jobs from `git status` and `git diff --name-only <base>...`:
   - only `docs/` or `*.md`: repo-hygiene only (all CI runs);
   - `pipeline/`, `scripts/*.sh` or a Dockerfile: the pipeline job;
   - `web/`, `pipeline/schema/` or `pipeline/tests/fixtures/` (the web
     tests read them): the web job. A schema change also needs `npm run
     layer-types`;
   - `docker-compose.yml` or `.env.example`: the compose job;
   - `pipeline/layers/*.yaml`: also `docker compose run --rm pipeline
     --status`, which lists any problem in a layer file.

   When unsure, or before marking a PR ready, run all four.
2. Start with `export MSYS_NO_PATHCONV=1` and the `repo=...` line. Run
   each command on its own and keep going after a failure. The first
   pipeline image build takes about 4 minutes, then seconds; the web
   checks about 15 seconds. Create no other image tags; every container
   uses `--rm`.
3. Report a short table: job, check, pass or fail. For each failure the
   file, line, message and fix. Fix only when asked, or when the fix is
   mechanical and in files the change already touches; then rerun that
   check.
