# CLAUDE.md

Working rules and durable context for this project. This file is loaded into
context automatically, so keep it to direction and rules, not a task list.

## Project name

{{PROJECT_NAME}}

## Project purpose

{{One or two paragraphs: what this project is, who it is for, and the core
idea in plain terms. See `docs/design/00_project_brief.md` for the full
brief.}}

## Project status

{{Where things stand right now: design, pre-build, MVP in progress, etc., and
what the next milestone is. Open GitHub issues are the live task tracker;
`docs/design/03_milestones.md` (if present) is the shape of the plan.}}

## Scope

{{What this project is, and just as importantly, what it deliberately is NOT.
Do not expand scope without a design note in `docs/design/` or an ADR in
`docs/decisions/`.}}

## Stack

{{Languages, frameworks, test runner, deployment target, and any hard
architectural constraints (for example: "business logic stays framework-free
under `src/core/` so it is unit-testable"). Link to the relevant ADR(s) in
`docs/decisions/` for the reasoning.}}

## Commands

{{The everyday commands: run, test, lint/typecheck, build. One line each, and
mark which ones are gates (non-zero exit blocks a merge). Say how long the
slow ones take and which ones CI skips, so nobody runs a 20 minute suite by
accident. Fill in once the stack is chosen; `CONTRIBUTING.md` Setup should
match.}}

## Repo structure

{{Optional: a short map of top-level directories, only if it adds real
orientation beyond exploring the tree. State layering rules here too, such as "`core/` never imports from `ui/`".
Keep it brief and expect it to drift; when in doubt, explore the tree rather
than trusting this section.}}

## Working rules

- Branch from `main`; one short-lived branch per change. Open a pull request
  into `main`; CI must pass before merge.
- Conventional Commits (for example `feat: ...`, `fix: ...`, `chore: ...`,
  `docs: ...`).
- No em dashes in code, comments, docs, commit messages, or user-facing text.
- Significant technical or design decisions get an ADR in `docs/decisions/`.
- Design notes live in `docs/design/`; session handoffs in `docs/handoffs/`.
- Keep changes small and focused; update docs when behaviour or design changes.
