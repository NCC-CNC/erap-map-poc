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

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| 0001 | Record architecture decisions | Accepted |
| 0002 | Bash pipeline with GDAL, tippecanoe and PMTiles | Accepted, amended by 0015 |
| 0003 | React, Vite, MapLibre and Chart.js web app | Accepted, amended by 0015 |
| 0004 | Docker Compose and static PMTiles serving | Accepted |
| 0005 | CARTO basemaps | Superseded by 0006 |
| 0006 | OpenFreeMap basemaps | Accepted |
| 0007 | Data-driven layer styles | Superseded by 0015 |
| 0008 | Binary raster layers as PNG tiles | Superseded in part by 0010 |
| 0009 | Local map config | Superseded by 0015 |
| 0010 | Raster layers as one COG each | Accepted |
| 0011 | Calculated fields and action rules | Superseded by 0015 |
| 0012 | Click modal template and colour themes | Superseded by 0015 |
| 0013 | Full detail at a vector layer's max zoom | Accepted |
| 0014 | GitHub Pages demo copy | Accepted |
| 0015 | One layer file and a MapLibre style | Accepted |
| 0016 | Coverage profile and drop guard | Accepted |
