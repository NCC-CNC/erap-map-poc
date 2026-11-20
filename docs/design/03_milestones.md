# 03 Milestones

The shape of the plan. Open GitHub issues are the live task tracker; each
milestone below is a GitHub milestone with issues under it.

## M0: Project setup (done)

The brief, CLAUDE.md, the stack ADRs, repo settings and auto-merge.

## M1: Skeleton end to end (done)

A synthetic layer goes from raw file to clickable feature: the pipeline
image, the web app with OpenFreeMap basemaps (ADR 0006), docker-compose,
pop-ups, the layer panel with legends, and CI. The test layers `sample`
and `sample_points` live in `pipeline/tests/layers/`.

## M2: Real data in (done)

The play data from November 2026: `ecoregions` and `protected_areas`
(file geodatabases) and the binary 30 m rasters `forest` and
`agriculture` as COGs (ADR 0010). Coverage tiling and the drop guard
(ADR 0016) and full detail at the max zoom (ADR 0013).

## M3: Styling and pop-ups (done)

Styles and the ecoregion dialog as decided in #14: order bottom to top
`forest`, `agriculture`, `protected_areas`, `ecoregions`; only
`ecoregions` is clickable, with "Colour by" themes (protected, Where To
Work, action recommendations) and a dialog (Summary, Habitat, Direct
threats, Opportunities, Action recommendations). Calculations happen in
the pipeline. The GitHub Pages copy (ADR 0014).

## Refactor (done)

One layer file and a MapLibre `style.json` (design note 04, ADR 0015):
steps 1 to 7 landed on `dev`, and after a full build from the real data
and a check in the browser `dev` merged into `main` (#158).

## M4: PoC review

- Short demo and write-up of what worked, limits found, and the
  recommendation (build out, change approach, or stop).
- Decide the deployment target if the PoC continues.

## Deferred

Decided in #13: not needed for the PoC. Revisit if it goes further or
the data is shared outside the team.

- Licence, provenance and update frequency of each dataset.
- Stable feature ids: `ecoregions` and `protected_areas` use `OBJECTID`,
  the geodatabase row id, which may change when the data is exported
  again. Nothing depends on it today; if that changes, use an integer
  copy of `ECOREGION_ID` in the source.
- Indigenous territories (needs a dataset), CPCAD attributes in a pop-up
  (needs the undissolved CPCAD), peatlands, French text.
- Categorical, continuous and multiband rasters.

## Open questions

- Ecoregion dialog texts and colours (#14) are placeholders until
  confirmed against the current ERAP app.
- The Where To Work (total area) theme uses `wtw_area_ha`; confirm it is
  the total area meant in #14.
- More action rules (#60): each is a calculated field and a list item in
  `ecoregions.yaml`. A landscape conservation count theme waits for its
  first rule.
- Do any pop-ups aggregate across many features? If so, precompute them
  in the pipeline.
