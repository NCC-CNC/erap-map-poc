import type { LayerDefinition } from './types';

/** Synthetic sample polygons built by the pipeline (issue #5). */
export const sample: LayerDefinition = {
  id: 'sample',
  title: 'Sample polygons',
  file: 'sample.pmtiles',
  sourceLayer: 'sample',
  defaultVisible: true,
  symbology: {
    geometry: 'polygon',
    // ColorBrewer YlGnBu, the four darker classes of the five-class scheme
    // (colour-blind safe, sequential). The palest class is left out so the
    // lowest scores still show on the light basemap.
    color: {
      type: 'stepped',
      attribute: 'score',
      stops: [
        { from: 0, color: '#a1dab4' },
        { from: 25, color: '#41b6c4' },
        { from: 50, color: '#2c7fb8' },
        { from: 75, color: '#253494' },
      ],
      max: 100,
      fallback: { color: '#9e9e9e', label: 'No score' },
    },
    fillOpacity: 0.7,
    outline: { color: '#ffffff', width: 0.75 },
  },
  popup: {
    title: { attribute: 'name' },
    stats: [
      { label: 'ID', value: { featureId: true } },
      { label: 'Area', value: { attribute: 'area_ha' }, format: { decimals: 1, suffix: 'ha' } },
      { label: 'Score', value: { attribute: 'score' }, format: { suffix: '/ 100' } },
    ],
    charts: [
      {
        type: 'bar',
        title: 'Value by year',
        valueLabel: 'Value',
        points: [2020, 2021, 2022, 2023, 2024].map((year) => ({
          label: String(year),
          attribute: `v${year}`,
        })),
      },
    ],
  },
};
