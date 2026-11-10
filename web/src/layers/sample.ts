import type { LayerDefinition } from './types';

/** Synthetic sample polygons built by the pipeline (issue #5). */
export const sample: LayerDefinition = {
  id: 'sample',
  title: 'Sample polygons',
  file: 'sample.pmtiles',
  sourceLayer: 'sample',
  layers: [
    {
      id: 'sample-fill',
      type: 'fill',
      paint: {
        'fill-color': '#2a9d8f',
        'fill-opacity': 0.35,
      },
    },
    {
      id: 'sample-outline',
      type: 'line',
      paint: {
        'line-color': '#1d6f65',
        'line-width': 1,
      },
    },
  ],
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
