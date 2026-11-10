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
    title: 'Sample feature',
  },
};
