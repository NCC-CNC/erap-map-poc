import type { LayerDefinition } from './types';

/** Synthetic sample points built by the pipeline (issue #32). */
export const samplePoints: LayerDefinition = {
  id: 'sample_points',
  title: 'Sample points',
  file: 'sample_points.pmtiles',
  sourceLayer: 'sample_points',
  defaultVisible: true,
  symbology: {
    geometry: 'point',
    // Okabe-Ito warm colours (colour-blind safe), chosen to stand apart from
    // the blue-green ramp of the sample polygons underneath.
    color: {
      type: 'categorical',
      attribute: 'category',
      categories: [
        { value: 'alpha', color: '#e69f00', label: 'Alpha' },
        { value: 'beta', color: '#cc79a7', label: 'Beta' },
        { value: 'gamma', color: '#d55e00', label: 'Gamma' },
      ],
      fallback: { color: '#9e9e9e', label: 'Other' },
    },
    radius: 6,
    stroke: { color: '#ffffff', width: 1.5 },
  },
  popup: {
    title: { attribute: 'name' },
    stats: [
      { label: 'ID', value: { featureId: true } },
      { label: 'Category', value: { attribute: 'category' } },
      { label: 'Count', value: { attribute: 'count' }, format: {} },
    ],
  },
};
