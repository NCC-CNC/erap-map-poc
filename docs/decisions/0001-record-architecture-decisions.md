# Record architecture decisions

## Status

Accepted

## Context

Significant technical and design choices (a new dependency, a stack or
framework choice, a scope decision that affects future work) need a durable
record of what was decided and why. Without one, the reasoning gets lost or
re-litigated.

## Decision

Record such decisions as short Architecture Decision Records (ADRs) in
`docs/decisions/`, one Markdown file per decision, named
`YYYY-MM-DD_short-title.md`. See `docs/decisions/README.md` for the format.

## Consequences

- Decisions and their rationale are discoverable later without digging through
  chat history or commit messages.
- Each ADR is small and specific, so writing one is low friction.
- A later decision that reverses an earlier one supersedes it with a new ADR
  rather than editing history.
