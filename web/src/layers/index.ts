/**
 * The data layers. None is defined in the app: they are read at runtime
 * from the pipeline's `manifest.json` (`./manifest.ts`, ADR 0007), so
 * changing or adding a layer means editing its `pipeline/layers/` files and
 * rerunning the pipeline, with no change here.
 */
export type {
  AttributesBlock,
  ChartBlock,
  ChartSeries,
  Color,
  Display,
  Format,
  FormatPreset,
  ListBlock,
  ModalBlock,
  ModalDefinition,
  ModalSection,
  TableBlock,
  Template,
  TextBlock,
  Theme,
  LayerDefinition,
  LayerType,
  Legend,
  LegendItem,
  BasemapName,
  MapDefaults,
  NumberFormat,
  PopupChart,
  PopupChartPoint,
  PopupDefinition,
  PopupStat,
  StyleLayer,
  ValueSource,
} from './types';
export {
  MESSAGES,
  ManifestError,
  displayProblems,
  drawOrder,
  loadManifest,
  mapDefaults,
  BASEMAP_NAMES,
  FORMAT_PRESETS,
  manifestUrl,
  parseManifest,
  type LoadOptions,
  type ManifestLayers,
} from './manifest';
export {
  RASTER_PNG_SOURCE,
  RASTER_SOURCE,
  isCog,
  styleLayerId,
  styleLayerIds,
  toMapLibre,
  visibilityValue,
  type MapLibreLayer,
} from './spec';
export {
  initialVisibility,
  isVisible,
  listOrder,
  visibilityUpdates,
  withVisibility,
  type VisibilityState,
} from './visibility';
export {
  activeLegend,
  activeTheme,
  themePaintUpdates,
  withTheme,
  type ThemeState,
} from './themes';
