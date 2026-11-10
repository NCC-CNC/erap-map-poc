import { sample } from './sample';
import type { LayerDefinition } from './types';

/**
 * The data layers shown on the map, bottom to top. To add a layer, create a
 * file next to `sample.ts` that exports a `LayerDefinition` and list it here;
 * the map setup reads this array and needs no other change.
 */
export const layerRegistry: readonly LayerDefinition[] = [sample];

export type { LayerDefinition, PopupDefinition, StyleLayer } from './types';
export { toMapLibre, type MapLibreLayer } from './spec';
