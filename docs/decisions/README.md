# Architecture Decision Records

This folder holds short Architecture Decision Records (ADRs) for significant
technical or design choices.

## When to add an ADR

Add an ADR when:

- A new dependency is introduced.
- A stack or framework choice is made or changed.
- A significant design pattern is adopted.
- A scope decision materially affects future work.

## Format

Use one Markdown file per decision, named:

`NNNN-short-title.md`

using the next free zero-padded sequence number (`0001`, `0002`, ...). A
decision that reverses an earlier one gets its own new-numbered file; mark the
old one `Superseded by NNNN-...` in its Status line rather than editing it.

Structure:

```markdown
# Title

## Status

Proposed | Accepted | Superseded by NNNN-...

## Context

Why this decision is needed.

## Decision

What was decided.

## Consequences

Positive and negative implications.
```

Keep each ADR short and specific.
