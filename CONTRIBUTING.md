# Contributing

Feedback, bug reports, and ideas are welcome through GitHub issues.

The workflow is:

1. Branch from `main` (one short-lived branch per change).
2. Keep changes small and focused.
3. Run the project checks locally before pushing (format, lint, tests, build).
   See the Setup section below for the exact commands once they are defined.
4. Open a pull request into `main`. CI must pass before merge.

## Setup

TODO (milestone M1): setup and local-run instructions. Planned: Docker with
Docker Compose is the only prerequisite; see the Commands section of
`CLAUDE.md` for the planned commands. A good shape:

- Prerequisites (tool and version).
- A short block that installs, runs, and checks. Make its last line the
  command CI runs, and say so.
- Pointers to `CLAUDE.md` for anything stack-specific or slow.

## Conventions

- Conventional Commits (for example `feat: ...`, `fix: ...`, `chore: ...`,
  `docs: ...`).
- No em dashes in code, comments, docs, commit messages, or user-facing text.
- See `CLAUDE.md` for the full working rules and `docs/` for design notes and
  decision records.
