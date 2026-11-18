/**
 * The data layers. None is defined in the app: they are read at runtime
 * from the pipeline's `style.json` (`./style.ts`, design note 04), so
 * changing or adding a layer means editing its `pipeline/layers/` file and
 * rerunning the pipeline, with no change here.
 */
export type {
  AttributesBlock,
  ChartBlock,
  ChartSeries,
  Color,
  Format,
  FormatPreset,
  LayerDefinition,
  LayerMetadata,
  LayerType,
  Legend,
  LegendConfig,
  LegendItem,
  Block,
  ListBlock,
  BasemapName,
  MapDefaults,
  NumberFormat,
  PopupDefinition,
  PopupLayout,
  PopupSize,
  PopupStat,
  Section,
  TableBlock,
  Template,
  TextBlock,
  Theme,
  ThemeConfig,
  ValueSource,
} from './types';
export {
  BASEMAP_NAMES,
  MESSAGES,
  StyleError,
  loadStyle,
  mapDefaults,
  parseStyle,
  styleUrl,
  type LoadOptions,
  type StyleLayers,
} from './style';
export { colorItems, deriveLegend, formatBound, resolveLegend } from './legend';
export {
  resolveSourceUrl,
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
