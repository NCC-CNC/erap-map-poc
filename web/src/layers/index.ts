import { sample } from './sample';
import { samplePoints } from './samplePoints';
import type { LayerDefinition } from './types';

/**
 * The data layers shown on the map, bottom to top (the last is drawn on
 * top and wins pop-up clicks where features overlap). To add a layer,
 * create a file next to `sample.ts` that exports a `LayerDefinition` and
 * list it here; the map setup and the layer list read this array and need
 * no other change.
 */
export const layerRegistry: readonly LayerDefinition[] = [sample, samplePoints];

export type {
  LayerDefinition,
  NumberFormat,
  PopupChart,
  PopupChartPoint,
  PopupDefinition,
  PopupStat,
  ValueSource,
} from './types';
export type {
  CategoricalColor,
  Color,
  ColorRule,
  Fallback,
  Legend,
  LegendItem,
  PointSymbology,
  PolygonSymbology,
  SingleColor,
  SteppedColor,
  StyleLayer,
  Symbology,
} from './symbology';
export { colorValue, legendFor, styleLayerIds, styleLayers } from './symbology';
export { toMapLibre, visibilityValue, type MapLibreLayer } from './spec';
export {
  initialVisibility,
  isVisible,
  listOrder,
  visibilityUpdates,
  withVisibility,
  type VisibilityState,
} from './visibility';
