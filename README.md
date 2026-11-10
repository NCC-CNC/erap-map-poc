# {{PROJECT_NAME}}

Stack-agnostic project harness for Claude Code workflows: no tech stack baked
in, just the process scaffolding: docs framework (design notes, ADRs,
handoffs), issue/PR templates, contribution and security policies, a license,
and Claude Code working rules (`CLAUDE.md`, `.claude/settings.json`).

## Using this template

1. Click "Use this template" on GitHub to create a new repo from this one.
2. Find and replace every `{{PROJECT_NAME}}` placeholder (README.md,
   CLAUDE.md) with your project's actual name.
3. Fill in `docs/design/00_project_brief.md`: replace every `{{...}}`
   placeholder with real content, or delete sections that do not apply
   (for example, the "Scope layers" section if the project has a single flat
   scope).
4. Fill in the `## Project purpose`, `## Project status`, `## Scope`, and
   `## Stack` sections of `CLAUDE.md` to match.
5. Pick a license. `LICENSE` here is GPL-3.0; swap it for whatever fits, and
   update the License section below.
6. Once a tech stack is chosen:
   - Fill in the `## Setup` section of `CONTRIBUTING.md` with real local-run
     commands.
   - Add your stack's own format/lint/typecheck/test/build job to
     `.github/workflows/ci.yml`, alongside the existing stack-neutral
     `repo-hygiene` job (markdown lint, no-em-dash check, docs-structure
     check, workflow lint). Do not replace that job; add another one next to
     it, copying the commented example, and add its name to the `needs` list
     of the `checks` job. The `changes` job lets a docs-only PR skip it.
   - Add a `package-ecosystem` entry to `.github/dependabot.yml` for your
     package manager (see the commented example there).
7. Run `scripts/bootstrap-repo-settings.sh` once (requires the GitHub CLI,
   authenticated with admin access on the new repo) to set branch protection
   on `main`, enable auto-merge, and create the starter label set. Templates
   do not carry repo settings over, only files, so this step is manual.
   It gates on the single `checks` job of `ci.yml`, which collects all the
   others, so adding a stack job later needs no change to branch protection.
   Note this only lets a PR *request* auto-merge; someone still has to click
   it. For a solo-maintainer repo, see "Solo-maintainer auto-merge" below.
8. Add your first ADR to `docs/decisions/` (see `docs/decisions/README.md`
   for the format; `docs/decisions/0001-record-architecture-decisions.md` is
   an example) for the stack choice you just made.
9. Delete this "Using this template" section once done, and replace it with
   real project usage instructions (what the project does for a user, how to
   run it).

## Solo-maintainer auto-merge (optional)

`.github/workflows-optional/` holds two workflows that make the owner's own
green PRs merge themselves. They are not active until you move them into
`.github/workflows/`.

- `auto-merge.yml` arms squash auto-merge on PRs opened by the repository
  owner (never on anyone else's, Dependabot included) and brings the PR level
  with `main`.
- `update-branches.yml` updates every armed PR after each push to `main`, so
  strict "up to date" branch protection does not leave them stuck BEHIND.

One-time setup: create a fine-grained personal access token for this repo only
(Contents, Pull requests and Workflows: read/write) and store it as the
`AUTO_MERGE_TOKEN` secret. `GITHUB_TOKEN` cannot be used because GitHub starts
no workflows for pushes or merges made with it, so the PR's checks would never
run on the updated branch. Rotate the PAT before it expires. `ci.yml` already
runs on PRs only: with strict protection every PR is tested against current
`main` before it merges.

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
  workflow (docs-only PRs skip stack jobs, one required `checks` status), and
  optional solo-maintainer auto-merge and cache-warming workflows.
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `LICENSE`.
- `scripts/bootstrap-repo-settings.sh`: one-time repo settings setup (branch
  protection, auto-merge, labels) that a template cannot carry over on its
  own.

## License

GNU General Public License v3.0. Replace with your own choice if different.
